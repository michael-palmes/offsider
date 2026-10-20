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

/// How many clients the broker serves at once, shared by the accept and client threads.
final class DeviceSessionClientCount: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    let limit: Int

    init(limit: Int) {
        self.limit = limit
    }

    var current: Int { lock.withLock { count } }

    /// False, leaving the count alone, when `limit` clients are already served.
    func claim() -> Bool {
        lock.withLock {
            guard count < limit else { return false }
            count += 1
            return true
        }
    }

    func release() { lock.withLock { count -= 1 } }
}

/// A set-once flag the accept thread reads.
final class DeviceSessionStopFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var set = false
    var isSet: Bool { lock.withLock { set } }
    func raise() { lock.withLock { set = true } }
}

/// Who may connect to the broker beyond the same user.
public enum DeviceSessionPeers: Sendable {
    /// Only code that satisfies this broker's own designated requirement, read when it starts.
    case ownSignature
    case requirement(PeerCodeIdentity.Requirement)
}

/// What the broker re-checks every 30 s while it runs: nil while it may go on, else the refusal it stops with.
public typealias DeviceSessionRecheck = @Sendable () async -> IOSDeviceError?

/// The per-device broker on a 0600 socket, ending on idle, `stop` or a lost device; input and frames each run one at a time, never waiting on the other.
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
    let maxLifetime: Duration
    let bodyTimeout: Duration
    let firstRequestTimeout: Duration
    let clients: DeviceSessionClientCount
    let peers: DeviceSessionPeers
    let recheck: DeviceSessionRecheck?
    let recheckInterval: Duration
    let log: IOSDeviceLog
    private let inputGate = DeviceSessionGate()
    private let frameGate = DeviceSessionGate()
    private let accepting = DeviceSessionStopFlag()
    private var lastRequest = ContinuousClock.now
    private var inFlight = 0
    private var stopping = false
    private var rechecking = false
    /// Set once a recheck refuses; every later request gets this refusal and the broker stops.
    private(set) var lapsed: IOSDeviceError?

    public init(
        udid: String, socketPath: String, hardware: any DeviceSessionHardware, store: DeviceSessionStore?,
        idleTimeout: Duration, healthInterval: Duration = .seconds(2), maxLifetime: Duration = DeviceSessionLimits.maxLifetime,
        bodyTimeout: Duration = DeviceSessionLimits.bodyTimeout, firstRequestTimeout: Duration = DeviceSessionLimits.firstRequestTimeout,
        maxClients: Int = DeviceSessionLimits.maxClients, peers: DeviceSessionPeers = .ownSignature, recheck: DeviceSessionRecheck? = nil, recheckInterval: Duration = DeviceSessionLimits.recheckInterval,
        log: @escaping IOSDeviceLog
    ) {
        self.udid = udid
        self.socketPath = socketPath
        self.hardware = hardware
        self.store = store
        self.idleTimeout = idleTimeout
        self.healthInterval = healthInterval
        self.maxLifetime = maxLifetime
        self.bodyTimeout = bodyTimeout
        self.firstRequestTimeout = firstRequestTimeout
        self.clients = DeviceSessionClientCount(limit: maxClients)
        self.peers = peers
        self.recheck = recheck
        self.recheckInterval = recheckInterval
        self.log = log
    }

    /// `OFFSIDER_IOS_SESSION_IDLE` seconds, 300 when unset or not a positive number, at most 3600.
    public static func idleSeconds(_ environment: [String: String]) -> Int {
        let seconds = environment[DeviceSessionManager.idleVariable].flatMap(Int.init).flatMap { $0 > 0 ? $0 : nil } ?? defaultIdleSeconds
        return DeviceSessionLimits.clampedIdle(seconds)
    }

    public func requestStop() {
        stopping = true
    }

    /// Listens, opens the stream, serves until idle, `stop` or the device goes, then ends the stream and removes the socket.
    public func run() async throws {
        let requirement: PeerCodeIdentity.Requirement
        switch peers {
        case .ownSignature:
            do {
                requirement = try PeerCodeIdentity.ownRequirement()
            } catch {
                throw IOSDeviceError(.sessionFailed, "The device session could not read its own code signature (\(error)), so it will not accept commands.")
            }
        case .requirement(let given):
            requirement = given
        }
        let listener = try Self.listen(at: socketPath, udid: udid)
        let identity = Self.socketIdentity(socketPath)
        log(.info, "Serving \(udid) on \(socketPath)")
        let started = ContinuousClock.now
        let timeouts = DeviceSessionTimeouts(first: min(firstRequestTimeout, idleTimeout), header: idleTimeout, body: bodyTimeout)
        let log = log
        let admits: @Sendable (Int32) -> Bool = { client in
            let verdict = PeerCodeIdentity.check(peer: client, requirement: requirement)
            if !verdict.accepted { log(.info, "Refused pid \(verdict.pid): it is not this Offsider build (\(verdict.detail ?? "no reason given"))") }
            return verdict.accepted
        }
        Self.acceptLoop(listener: listener, flag: accepting, udid: udid, clients: clients, timeouts: timeouts, admits: admits) { [weak self] id, request, origin in
            await self?.handle(id: id, request: request, origin: origin) ?? (.failure(id: id, IOSDeviceError(.sessionFailed, "The device session is shutting down.")), nil)
        }
        Task { await hardware.start() }
        var nextHealth = ContinuousClock.now + healthInterval
        var nextRecheck = started + recheckInterval
        while !stopping {
            try? await Task.sleep(for: .milliseconds(50))
            let now = ContinuousClock.now
            if let lapsed {
                log(.info, "Stopping: \(lapsed.message)")
                break
            }
            if let recheck, !rechecking, now >= nextRecheck {
                rechecking = true
                Task { [weak self] in
                    let refusal = await Task.detached { await recheck() }.value
                    self?.finishRecheck(refusal)
                }
                nextRecheck = now + recheckInterval
            }
            if inFlight == 0, now - lastRequest >= idleTimeout {
                log(.info, "Stopping: idle for \(idleTimeout)")
                break
            }
            if inFlight == 0, now - started >= maxLifetime {
                log(.info, "Stopping: running for \(maxLifetime); the next command starts a fresh session")
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

    private func finishRecheck(_ refusal: IOSDeviceError?) {
        rechecking = false
        if let refusal, lapsed == nil { lapsed = refusal }
    }

    func handle(id: Int, request: DeviceSessionRequest, origin: DeviceSessionOrigin = .detached) async -> (DeviceSessionReply, Data?) {
        if let lapsed, request != .stop { return (.failure(id: id, lapsed), nil) }
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
        case .press, .touch, .keys:
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
            guard DeviceSessionLimits.allowsButton(page: page, code: code) else {
                throw IOSDeviceError(.sessionFailed, "The device session presses only the home, lock, side and Siri buttons; it refused usage \(String(format: "0x%llX", page)):\(String(format: "0x%llX", code)).")
            }
            try await hardware.press(usagePage: page, usageCode: code, hold: hold, abandoned: origin.isGone)
        case .touch(let steps):
            try DeviceSessionLimits.checkBudget(steps)
            try await hardware.touch(steps, abandoned: origin.isGone)
        case .keys(let steps):
            try DeviceSessionLimits.checkBudget(steps)
            try await hardware.keys(steps, abandoned: origin.isGone)
        case .stop:
            stopping = true
        case .displayChanged:
            hardware.displayChanged()
        }
        return (reply, nil)
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

    /// Binds `path` 0600 inside a private folder; refuses when a broker already answers there, and replaces a stale socket this user owns.
    nonisolated static func listen(at path: String, udid: String) throws -> Int32 {
        do {
            return try UnixSocket.listen(at: path)
        } catch UnixSocketError.alreadyServed {
            throw IOSDeviceError(.sessionFailed, "Another device session already serves \(udid) on \(path).")
        } catch UnixSocketError.notOwnedSocket {
            throw IOSDeviceError(.sessionFailed, "\(path) is not a socket this user owns, so Offsider will not replace it.")
        } catch UnixSocketError.system(let operation, _, let code) {
            throw IOSDeviceError(.sessionFailed, "The device session could not \(operation) \(path): \(String(cString: strerror(code))).")
        } catch UnixSocketError.pathTooLong {
            throw DeviceSessionWireError(detail: "the socket path \(path) is too long")
        }
    }

    nonisolated static func socketIdentity(_ path: String) -> [UInt64]? {
        UnixSocket.identity(path)
    }

    nonisolated static func isSameUser(_ descriptor: Int32, uid: uid_t = getuid()) -> Bool {
        UnixSocket.isSameUser(descriptor, uid: uid)
    }

    typealias Handler = @Sendable (Int, DeviceSessionRequest, DeviceSessionOrigin) async -> (DeviceSessionReply, Data?)

    static let busyRefusal = IOSDeviceError(
        .sessionFailed,
        "The device session already serves \(DeviceSessionLimits.maxClients) commands at once, so it refused this one. Retry when one finishes."
    )

    /// Accepts on its own thread and serves each client on another, up to the client limit; another user's client is closed unread.
    nonisolated static func acceptLoop(
        listener: Int32, flag: DeviceSessionStopFlag, udid: String, clients: DeviceSessionClientCount, timeouts: DeviceSessionTimeouts,
        admits: @escaping @Sendable (Int32) -> Bool, handler: @escaping Handler
    ) {
        let refusals = DeviceSessionClientCount(limit: clients.limit)
        let thread = Thread {
            while !flag.isSet {
                var poller = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
                guard poll(&poller, 1, 100) > 0, !flag.isSet else { continue }
                let client = CloseOnExecSocket.accept(listener)
                guard client >= 0 else { continue }
                // Another user's client, or code other than this Offsider build, is closed before it gets a byte.
                guard isSameUser(client), admits(client) else {
                    Darwin.close(client)
                    continue
                }
                let channel = DeviceSessionChannel(descriptor: client)
                if clients.claim() {
                    Thread {
                        defer { clients.release() }
                        serveClient(channel, timeouts: timeouts, handler: handler)
                    }.start()
                } else if refusals.claim() {
                    Thread {
                        defer { refusals.release() }
                        refuse(channel, timeouts: timeouts)
                    }.start()
                } else {
                    channel.close()
                }
            }
        }
        thread.start()
    }

    /// Reads the waiting request, so the refusal answers its id, then closes.
    nonisolated static func refuse(_ channel: DeviceSessionChannel, timeouts: DeviceSessionTimeouts) {
        defer { channel.close() }
        let wait = min(timeouts.body, .seconds(2))
        let payload = try? channel.readFrame(limit: DeviceSessionWire.maxJSONBytes, timeout: wait)
        let id = payload.flatMap { try? JSONDecoder().decode(DeviceSessionRequest.Envelope.self, from: $0) }?.id ?? 0
        guard let reply = try? DeviceSessionWire.encoder.encode(DeviceSessionReply.failure(id: id, busyRefusal)) else { return }
        try? channel.write(DeviceSessionWire.frame(reply), timeout: .seconds(2))
    }

    /// Reads requests until the client closes or stays silent: 10 s before its first request, the idle timeout between later ones.
    /// Each reply, and any frame it announces, is written before the next read.
    nonisolated static func serveClient(_ channel: DeviceSessionChannel, timeouts: DeviceSessionTimeouts, handler: @escaping Handler) {
        defer { channel.close() }
        var wait = timeouts.first
        while true {
            guard let payload = try? channel.readFrame(limit: DeviceSessionWire.maxJSONBytes, timeout: wait, bodyTimeout: timeouts.body) else { return }
            wait = timeouts.header
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

/// How long a new client may stay silent before its first request, how long between later ones (the idle timeout), and how long a started request may take to arrive.
struct DeviceSessionTimeouts: Sendable {
    let first: Duration
    let header: Duration
    let body: Duration
}

extension DeviceSessionServer {
    /// The refusal a broker stops with once usbmuxd no longer lists its device on USB; nil while it does.
    public nonisolated static func usbRefusal(udid: String, usbmux: any UsbmuxListing) -> IOSDeviceError? {
        if (try? usbmux.listsOnUSB(udid)) == true { return nil }
        return IOSDeviceError(.notWired, "\(udid) is no longer connected over USB, so its device session stopped and sent nothing more. Connect its cable, then retry.")
    }
}

private final class ResultBox<T>: @unchecked Sendable {
    var value: T?
}
