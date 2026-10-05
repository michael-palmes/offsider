import Darwin
import Foundation
import OffsiderCore

/// What the broker holds for its device; `CoreDeviceSessionHardware` on a device, a fake in tests.
@MainActor
public protocol DeviceSessionHardware: AnyObject {
    /// Opens the stream; a failure is kept in `streamStatus`, never thrown.
    func start() async
    var streamStatus: DeviceSessionStreamStatus { get }
    /// True when touches and keys go out through the broker.
    var supportsTouch: Bool { get }
    /// The device's model label, once known.
    var label: String? { get }
    /// The main display if read within the last second, so a command can skip reading it; nil starts a read.
    func freshGeometry() -> IOSDeviceGeometry?
    /// The screen turned, so the display is read again before the next touch.
    func displayChanged()
    func frame(_ format: IOSDeviceScreenFrame.Format) async throws -> IOSDeviceScreenFrame
    /// Input stops early, releasing what it holds, once `abandoned` reports its client gone.
    func press(usagePage: UInt64, usageCode: UInt64, hold: Double, abandoned: @Sendable () -> Bool) async throws
    func touch(_ steps: [DeviceSessionStep], abandoned: @Sendable () -> Bool) async throws
    func keys(_ steps: [DeviceSessionStep], abandoned: @Sendable () -> Bool) async throws
    /// False once the device has gone, so the broker exits; starts re-opening a stream that died without waiting for it.
    func checkHealth() async -> Bool
    /// Ends the stream on the device and closes every socket.
    func close() async
}

/// Runs bodies one at a time on the main actor, in arrival order, across their suspension points.
@MainActor
final class DeviceSessionGate {
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func run<T>(_ body: () async -> T) async -> T {
        if busy {
            await withCheckedContinuation { waiters.append($0) }
        } else {
            busy = true
        }
        let result = await body()
        if waiters.isEmpty {
            busy = false
        } else {
            waiters.removeFirst().resume()
        }
        return result
    }
}

/// The client behind a request: when the request arrived, and whether the client has since disconnected.
public struct DeviceSessionOrigin: Sendable {
    public let receivedAt: ContinuousClock.Instant
    public let isGone: @Sendable () -> Bool

    public init(receivedAt: ContinuousClock.Instant, isGone: @escaping @Sendable () -> Bool) {
        self.receivedAt = receivedAt
        self.isGone = isGone
    }

    static var detached: Self { Self(receivedAt: .now, isGone: { false }) }
}

/// A set-once flag the accept thread reads.
final class DeviceSessionStopFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var set = false
    var isSet: Bool { lock.withLock { set } }
    func raise() { lock.withLock { set = true } }
}

/// The per-device broker: one 0600 Unix socket for this user, exiting on idle, `stop` or a lost device.
/// Input requests run one at a time, as do frame requests, and neither waits on the other or on stream recovery.
@MainActor
public final class DeviceSessionServer {
    public static let defaultIdleSeconds = 300
    /// Input that waited longer than this to start is dropped unsent: its client is about to give up on the reply.
    static let staleInputAge: Duration = DeviceSessionClient.inputTimeout - .seconds(5)

    let udid: String
    let socketPath: String
    let hardware: any DeviceSessionHardware
    let store: DeviceSessionStore?
    let idleTimeout: Duration
    let healthInterval: Duration
    let log: IOSDeviceLog
    private let inputGate = DeviceSessionGate()
    private let frameGate = DeviceSessionGate()
    private let accepting = DeviceSessionStopFlag()
    private var lastRequest = ContinuousClock.now
    private var inFlight = 0
    private var stopping = false

    public init(
        udid: String, socketPath: String, hardware: any DeviceSessionHardware, store: DeviceSessionStore?,
        idleTimeout: Duration, healthInterval: Duration = .seconds(2), log: @escaping IOSDeviceLog
    ) {
        self.udid = udid
        self.socketPath = socketPath
        self.hardware = hardware
        self.store = store
        self.idleTimeout = idleTimeout
        self.healthInterval = healthInterval
        self.log = log
    }

    /// `OFFSIDER_IOS_SESSION_IDLE` seconds, 300 when unset or not a positive number.
    public static func idleSeconds(_ environment: [String: String]) -> Int {
        environment[DeviceSessionManager.idleVariable].flatMap(Int.init).flatMap { $0 > 0 ? $0 : nil } ?? defaultIdleSeconds
    }

    public func requestStop() {
        stopping = true
    }

    /// Listens, opens the stream, serves until idle, `stop` or the device goes, then ends the stream and removes the socket.
    public func run() async throws {
        let listener = try Self.listen(at: socketPath, udid: udid)
        let identity = Self.socketIdentity(socketPath)
        log(.info, "Serving \(udid) on \(socketPath)")
        Self.acceptLoop(listener: listener, flag: accepting, udid: udid) { [weak self] id, request, origin in
            await self?.handle(id: id, request: request, origin: origin) ?? (.failure(id: id, IOSDeviceError(.sessionFailed, "The device session is shutting down.")), nil)
        }
        Task { await hardware.start() }
        var nextHealth = ContinuousClock.now + healthInterval
        while !stopping {
            try? await Task.sleep(for: .milliseconds(50))
            let now = ContinuousClock.now
            if inFlight == 0, now - lastRequest >= idleTimeout {
                log(.info, "Stopping: idle for \(idleTimeout)")
                break
            }
            if now >= nextHealth {
                let healthy = await hardware.checkHealth()
                if !healthy {
                    log(.info, "Stopping: \(udid) is no longer reachable")
                    break
                }
                nextHealth = ContinuousClock.now + healthInterval
            }
        }
        accepting.raise()
        Darwin.close(listener)
        if let identity, Self.socketIdentity(socketPath) == identity { unlink(socketPath) }
        await inputGate.run { await frameGate.run { await hardware.close() } }
        store?.remove(udid: udid, ifPID: getpid())
        log(.info, "Stopped")
    }

    func handle(id: Int, request: DeviceSessionRequest, origin: DeviceSessionOrigin = .detached) async -> (DeviceSessionReply, Data?) {
        lastRequest = .now
        inFlight += 1
        defer {
            inFlight -= 1
            lastRequest = .now
        }
        switch request {
        case .ping:
            return (pingReply(id), nil)
        case .stop:
            stopping = true
            return (DeviceSessionReply(id: id), nil)
        case .displayChanged:
            hardware.displayChanged()
            return (DeviceSessionReply(id: id), nil)
        case .frame:
            return await frameGate.run { await self.reply(id: id, request, origin: origin) }
        case .press, .touch, .keys, .text:
            return await inputGate.run {
                if let unsent = Self.unsent(origin, now: .now) { return (.failure(id: id, unsent), nil) }
                return await self.reply(id: id, request, origin: origin)
            }
        }
    }

    private func reply(id: Int, _ request: DeviceSessionRequest, origin: DeviceSessionOrigin) async -> (DeviceSessionReply, Data?) {
        do {
            return try await serve(id: id, request, origin: origin)
        } catch {
            return (.failure(id: id, error), nil)
        }
    }

    /// Why queued input is dropped before it is sent: its client has gone, or has waited so long it will not see the reply.
    static func unsent(_ origin: DeviceSessionOrigin, now: ContinuousClock.Instant) -> IOSDeviceError? {
        if origin.isGone() {
            return IOSDeviceError(.sessionFailed, "The command disconnected before its input was sent, so the device session did not send it.")
        }
        if now - origin.receivedAt > staleInputAge {
            return IOSDeviceError(.sessionFailed, "The device session was busy for over \(staleInputAge.components.seconds) seconds, so it dropped this input unsent. Retry.")
        }
        return nil
    }

    private func serve(id: Int, _ request: DeviceSessionRequest, origin: DeviceSessionOrigin) async throws -> (DeviceSessionReply, Data?) {
        var reply = DeviceSessionReply(id: id)
        switch request {
        case .ping:
            return (pingReply(id), nil)
        case .frame(let format):
            let frame = try await hardware.frame(format)
            reply.bytes = frame.data.count
            reply.width = frame.width
            reply.height = frame.height
            reply.format = format.wireName
            return (reply, frame.data)
        case let .press(page, code, hold):
            guard hold >= 0, hold <= 10 else { throw IOSDeviceError(.sessionFailed, "A button hold of \(hold) s is outside 0 to 10 s.") }
            try await hardware.press(usagePage: page, usageCode: code, hold: hold, abandoned: origin.isGone)
        case .touch(let steps):
            try Self.checkTiming(steps)
            try await hardware.touch(steps, abandoned: origin.isGone)
        case .keys(let steps):
            try Self.checkTiming(steps)
            try await hardware.keys(steps, abandoned: origin.isGone)
        case .text(let text):
            try await hardware.keys(try DeviceSessionLowering.keySteps(typing: text), abandoned: origin.isGone)
        case .stop:
            stopping = true
        case .displayChanged:
            hardware.displayChanged()
        }
        return (reply, nil)
    }

    static func checkTiming(_ steps: [DeviceSessionStep]) throws {
        guard steps.allSatisfy({ $0.kind != .wait || (($0.seconds ?? -1) >= 0 && ($0.seconds ?? 0) <= 30) }) else {
            throw IOSDeviceError(.sessionFailed, "A wait in the input steps is outside 0 to 30 s.")
        }
    }

    private func pingReply(_ id: Int) -> DeviceSessionReply {
        var reply = DeviceSessionReply(id: id)
        reply.protocol = DeviceSessionWire.protocolVersion
        reply.pid = getpid()
        reply.udid = udid
        reply.label = hardware.label
        reply.geometry = hardware.freshGeometry()
        reply.stream = hardware.streamStatus
        reply.touch = hardware.supportsTouch
        reply.idleSeconds = Int(idleTimeout.components.seconds)
        return reply
    }

    // MARK: Socket

    /// Binds `path` 0600; refuses when a broker already answers there, and replaces a stale socket this user owns.
    nonisolated static func listen(at path: String, udid: String) throws -> Int32 {
        if let channel = try? DeviceSessionChannel.connect(to: path) {
            channel.close()
            throw IOSDeviceError(.sessionFailed, "Another device session already serves \(udid) on \(path).")
        }
        var info = stat()
        if lstat(path, &info) == 0 {
            guard (info.st_mode & S_IFMT) == S_IFSOCK, info.st_uid == getuid() else {
                throw IOSDeviceError(.sessionFailed, "\(path) is not a socket this user owns, so Offsider will not replace it.")
            }
            unlink(path)
        }
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw posix("socket", path) }
        var on: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        do {
            var address = try DeviceSessionChannel.unixAddress(path)
            let previous = umask(0o177)
            let bound = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
            }
            umask(previous)
            guard bound == 0 else { throw posix("bind", path) }
            guard chmod(path, S_IRUSR | S_IWUSR) == 0 else { throw posix("chmod", path) }
            guard Darwin.listen(descriptor, SOMAXCONN) == 0 else { throw posix("listen", path) }
            return descriptor
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    nonisolated static func posix(_ operation: String, _ path: String) -> IOSDeviceError {
        IOSDeviceError(.sessionFailed, "The device session could not \(operation) \(path): \(String(cString: strerror(errno))).")
    }

    nonisolated static func socketIdentity(_ path: String) -> [UInt64]? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        return [UInt64(info.st_dev), UInt64(info.st_ino)]
    }

    nonisolated static func isSameUser(_ descriptor: Int32, uid: uid_t = getuid()) -> Bool {
        var peerUID: uid_t = 0
        var peerGID: gid_t = 0
        return getpeereid(descriptor, &peerUID, &peerGID) == 0 && peerUID == uid
    }

    typealias Handler = @Sendable (Int, DeviceSessionRequest, DeviceSessionOrigin) async -> (DeviceSessionReply, Data?)

    /// Accepts on its own thread and serves each client on another; another user's client is closed unread.
    nonisolated static func acceptLoop(listener: Int32, flag: DeviceSessionStopFlag, udid: String, handler: @escaping Handler) {
        let thread = Thread {
            while !flag.isSet {
                var poller = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
                guard poll(&poller, 1, 100) > 0, !flag.isSet else { continue }
                let client = accept(listener, nil, nil)
                guard client >= 0 else { continue }
                guard isSameUser(client) else {
                    Darwin.close(client)
                    continue
                }
                let channel = DeviceSessionChannel(descriptor: client)
                let worker = Thread { serveClient(channel, handler: handler) }
                worker.start()
            }
        }
        thread.start()
    }

    /// Reads requests until the client closes; each reply, and any frame it announces, is written before the next read.
    nonisolated static func serveClient(_ channel: DeviceSessionChannel, handler: @escaping Handler) {
        defer { channel.close() }
        while true {
            guard let payload = try? channel.readFrame(limit: DeviceSessionWire.maxJSONBytes, timeout: nil) else { return }
            let reply: DeviceSessionReply
            var data: Data?
            do {
                let (id, request) = try DeviceSessionWire.decodeRequest(payload)
                let origin = DeviceSessionOrigin(receivedAt: .now, isGone: { channel.peerClosed() })
                (reply, data) = blocking { await handler(id, request, origin) }
            } catch {
                let id = (try? JSONDecoder().decode(DeviceSessionRequest.Envelope.self, from: payload))?.id ?? 0
                let detail = (error as? DeviceSessionWireError)?.detail ?? "an unreadable request"
                reply = .failure(id: id, IOSDeviceError(.sessionFailed, "The device session could not read the request: \(detail)."))
            }
            do {
                try channel.write(DeviceSessionWire.frame(try DeviceSessionWire.encoder.encode(reply)), timeout: .seconds(10))
                if let data { try channel.write(DeviceSessionWire.frame(data), timeout: .seconds(10)) }
            } catch {
                return
            }
        }
    }

    private nonisolated static func blocking<T: Sendable>(_ body: @escaping @Sendable () async -> T) -> T {
        let box = ResultBox<T>()
        let done = DispatchSemaphore(value: 0)
        Task {
            box.value = await body()
            done.signal()
        }
        done.wait()
        return box.value!
    }
}

private final class ResultBox<T>: @unchecked Sendable {
    var value: T?
}
