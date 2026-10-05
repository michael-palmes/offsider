import Darwin
import Foundation
import OffsiderCore

/// Why an exchange with the broker failed: before the request was written, or after.
enum DeviceSessionLinkError: Error, Equatable, Sendable {
    case notSent(String)
    case lost(String)
}

/// One connection to a broker; `SocketSessionLink` in production, a fake in tests.
protocol DeviceSessionLink: AnyObject, Sendable {
    /// The reply, and the binary frame when the reply announced one.
    func exchange(_ request: DeviceSessionRequest, timeout: Duration) async throws -> (DeviceSessionReply, Data?)
    /// True once a failed write or a lost reply has ended the connection, so a new one is needed.
    var isBroken: Bool { get }
    func close()
}

/// Blocking frame I/O on its own queue, one request at a time; a lost reply breaks the link for good.
final class SocketSessionLink: DeviceSessionLink, @unchecked Sendable {
    private let channel: DeviceSessionChannel
    private let queue = DispatchQueue(label: "offsider.device-session.client")
    private let state = NSLock()
    private var nextID = 1
    private var broken = false

    init(channel: DeviceSessionChannel) {
        self.channel = channel
    }

    static func connect(_ path: String) throws -> any DeviceSessionLink {
        SocketSessionLink(channel: try DeviceSessionChannel.connect(to: path))
    }

    var isBroken: Bool { state.withLock { broken } }

    func exchange(_ request: DeviceSessionRequest, timeout: Duration) async throws -> (DeviceSessionReply, Data?) {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(with: Result { try self.blockingExchange(request, timeout: timeout) })
            }
        }
    }

    private func breakLink() {
        state.withLock { broken = true }
    }

    private func blockingExchange(_ request: DeviceSessionRequest, timeout: Duration) throws -> (DeviceSessionReply, Data?) {
        guard !isBroken else { throw DeviceSessionLinkError.notSent("its connection broke on an earlier request") }
        let id = nextID
        nextID += 1
        do {
            try channel.write(try DeviceSessionWire.encode(request, id: id))
        } catch {
            breakLink()
            throw DeviceSessionLinkError.notSent(Self.detail(error))
        }
        do {
            guard let payload = try channel.readFrame(limit: DeviceSessionWire.maxJSONBytes, timeout: timeout) else {
                throw DeviceSessionWireError(detail: "the broker closed the connection")
            }
            let reply = try JSONDecoder().decode(DeviceSessionReply.self, from: payload)
            guard reply.id == id else { throw DeviceSessionWireError(detail: "a reply to another request") }
            guard reply.ok, let bytes = reply.bytes else { return (reply, nil) }
            let frame = try channel.readFrame(limit: DeviceSessionWire.maxPayloadBytes, timeout: timeout) ?? Data()
            guard frame.count == bytes else { throw DeviceSessionWireError(detail: "a frame of \(frame.count) bytes after announcing \(bytes)") }
            return (reply, frame)
        } catch {
            breakLink()
            channel.close()
            throw DeviceSessionLinkError.lost(Self.detail(error))
        }
    }

    private static func detail(_ error: Error) -> String {
        (error as? DeviceSessionWireError)?.detail ?? "\(error)"
    }

    func close() {
        channel.close()
    }
}

/// A command's connection to one device's session broker.
@MainActor
public final class DeviceSessionClient {
    public nonisolated static let pingTimeout: Duration = .seconds(2)
    public nonisolated static let frameTimeout: Duration = .seconds(20)
    nonisolated static let inputTimeout: Duration = .seconds(30)

    public let udid: String
    let link: any DeviceSessionLink
    /// The broker's latest `ping`.
    public private(set) var status: DeviceSessionReply?

    init(udid: String, link: any DeviceSessionLink) {
        self.udid = udid
        self.link = link
    }

    /// The broker sends touches and keys itself; otherwise they go through the runner.
    public var supportsTouch: Bool { status?.touch == true }

    /// The connection failed or lost a reply, so every later request would be refused unsent.
    var isBroken: Bool { link.isBroken }

    @discardableResult
    public func ping(timeout: Duration = pingTimeout) async throws -> DeviceSessionReply {
        let (reply, _) = try await call(.ping, timeout: timeout)
        status = reply
        return reply
    }

    public func frame(_ format: IOSDeviceScreenFrame.Format, timeout: Duration = frameTimeout) async throws -> IOSDeviceScreenFrame {
        let (reply, payload) = try await call(.frame(format), timeout: timeout)
        guard let payload, let width = reply.width, let height = reply.height else {
            throw IOSDeviceError(.sessionFailed, "The device session for \(udid) answered a frame request without a frame. Retry; `offsider session stop --device \(udid)` restarts it.")
        }
        return IOSDeviceScreenFrame(data: payload, width: width, height: height, format: format)
    }

    public func press(usagePage: UInt64, usageCode: UInt64, hold: Double) async throws {
        _ = try await call(.press(usagePage: usagePage, usageCode: usageCode, hold: hold), timeout: Self.inputTimeout + .seconds(hold))
    }

    public func touch(_ steps: [DeviceSessionStep]) async throws {
        _ = try await call(.touch(steps), timeout: Self.inputTimeout + .seconds(Self.waited(steps)))
    }

    public func keys(_ steps: [DeviceSessionStep]) async throws {
        _ = try await call(.keys(steps), timeout: Self.inputTimeout + .seconds(Self.waited(steps)))
    }

    public func text(_ text: String) async throws {
        _ = try await call(.text(text), timeout: Self.inputTimeout + .seconds(Double(text.count) * 0.1))
    }

    public func displayChanged() async throws {
        _ = try await call(.displayChanged, timeout: Self.pingTimeout)
    }

    public func stop(timeout: Duration = .seconds(8)) async throws {
        _ = try await call(.stop, timeout: timeout)
    }

    public func close() {
        link.close()
    }

    static func waited(_ steps: [DeviceSessionStep]) -> Double {
        steps.reduce(0) { $0 + ($1.kind == .wait ? max($1.seconds ?? 0, 0) : 0) }
    }

    func call(_ request: DeviceSessionRequest, timeout: Duration) async throws -> (DeviceSessionReply, Data?) {
        let reply: DeviceSessionReply
        let payload: Data?
        do {
            (reply, payload) = try await link.exchange(request, timeout: timeout)
        } catch DeviceSessionLinkError.notSent(let detail) {
            throw IOSDeviceError(
                .sessionFailed,
                "The device session for \(udid) did not take the request (\(detail)), so nothing was sent. Retry; `offsider session stop --device \(udid)` restarts it."
            )
        } catch DeviceSessionLinkError.lost(let detail) {
            if request.sendsInput {
                throw IOSDeviceError(
                    .sessionLost,
                    "The device session for \(udid) stopped answering after the input was sent (\(detail)), so it may have reached the device and was not resent. Check the screen before resending."
                )
            }
            throw IOSDeviceError(.sessionFailed, "The device session for \(udid) stopped answering (\(detail)). Retry; `offsider session stop --device \(udid)` restarts it.")
        }
        if !reply.ok {
            throw reply.error?.error ?? IOSDeviceError(.sessionFailed, "The device session for \(udid) refused `\(request.op)` without saying why.")
        }
        return (reply, payload)
    }
}

/// Returns a client whose broker has answered `ping`; `DeviceSessionManager` in production, a fake in tests.
@MainActor
public protocol DeviceSessionConnecting: AnyObject, Sendable {
    func connect(udid: String) async throws -> DeviceSessionClient
    /// A live broker that answers, never started.
    func existing(udid: String) async -> DeviceSessionClient?
}

/// What `session status` shows for one broker.
public struct DeviceSessionStatus: Equatable, Sendable {
    public let record: DeviceSessionRecord
    public let alive: Bool
    /// The broker's `ping`; nil when it did not answer.
    public let reply: DeviceSessionReply?

    public init(record: DeviceSessionRecord, alive: Bool, reply: DeviceSessionReply?) {
        self.record = record
        self.alive = alive
        self.reply = reply
    }
}

/// Reuses a device's live broker or starts one, through `session.json` and a start lock.
@MainActor
public final class DeviceSessionManager: DeviceSessionConnecting {
    public static let idleVariable = "OFFSIDER_IOS_SESSION_IDLE"
    public static let serveArguments = ["device-session", "serve", "--device"]
    static let pollInterval: Duration = .milliseconds(20)
    static let lockPollInterval: Duration = .milliseconds(50)

    let store: DeviceSessionStore
    let processes: any RunnerProcessControlling
    let environment: [String: String]
    let connector: @Sendable (String) throws -> any DeviceSessionLink
    let log: IOSDeviceLog
    let now: @Sendable () -> Date
    let startTimeout: Duration
    let lockTimeout: TimeInterval

    public convenience init(
        store: DeviceSessionStore, processes: any RunnerProcessControlling, environment: [String: String], log: @escaping IOSDeviceLog
    ) {
        self.init(store: store, processes: processes, environment: environment, connector: { try SocketSessionLink.connect($0) }, log: log)
    }

    init(
        store: DeviceSessionStore,
        processes: any RunnerProcessControlling,
        environment: [String: String],
        connector: @escaping @Sendable (String) throws -> any DeviceSessionLink,
        log: @escaping IOSDeviceLog,
        now: @escaping @Sendable () -> Date = { Date() },
        startTimeout: Duration = .seconds(20),
        lockTimeout: TimeInterval = 40
    ) {
        self.store = store
        self.processes = processes
        self.environment = environment
        self.connector = connector
        self.log = log
        self.now = now
        self.startTimeout = startTimeout
        self.lockTimeout = lockTimeout
    }

    public func existing(udid: String) async -> DeviceSessionClient? {
        await reuse(udid: udid, holdingLock: false, stopStale: false)
    }

    public func connect(udid: String) async throws -> DeviceSessionClient {
        if let client = await reuse(udid: udid, holdingLock: false) { return client }
        let lock = try await acquireStartLock(udid: udid)
        defer { lock.release() }
        if let client = await reuse(udid: udid, holdingLock: true) { return client }
        return try await start(udid: udid)
    }

    /// The recorded broker while it is still that process and answers `ping`; a dead one is forgotten, never signalled.
    func reuse(udid: String, holdingLock: Bool, stopStale: Bool = true) async -> DeviceSessionClient? {
        guard var record = try? store.read(udid: udid) else { return nil }
        guard processes.isRunning(record) else {
            log(.debug, "Forgetting the device session on \(udid): its process has exited")
            store.remove(udid: udid)
            return nil
        }
        if record.state == .starting, !holdingLock { return nil }
        if let client = await answering(record.socket, udid: udid) {
            if record.state != .running {
                record.state = .running
                try? store.write(record)
            }
            return client
        }
        if holdingLock, record.state == .starting, let client = await awaitBroker(record) {
            record.state = .running
            try? store.write(record)
            return client
        }
        guard stopStale else { return nil }
        log(.debug, "Restarting the device session on \(udid): it did not answer")
        await stop(record)
        return nil
    }

    func start(udid: String) async throws -> DeviceSessionClient {
        let socket = try store.socketPath(udid: udid)
        let logPath = try store.logPath(udid: udid)
        unlink(logPath)
        let pid: Int32
        do {
            pid = try processes.launch(arguments: Self.serveArguments + [udid], environment: environment, logPath: logPath)
        } catch {
            throw IOSDeviceError(.sessionFailed, "Offsider could not start the device session for \(udid): \(error.localizedDescription). Run `offsider doctor --device \(udid)`.")
        }
        var record = DeviceSessionRecord(
            udid: udid, pid: pid, process: processes.identity(of: pid), socket: socket, startedAt: now(), version: DeviceSessionWire.protocolVersion, state: .starting
        )
        if record.process != nil { try store.write(record) }
        if let client = await awaitBroker(record) {
            record.state = .running
            try? store.write(record)
            return client
        }
        if let identity = record.process { processes.terminate(pid, identity: identity) }
        store.remove(udid: udid)
        throw IOSDeviceError(
            .sessionFailed,
            "The device session for \(udid) did not start within \(startTimeout.components.seconds) seconds. Retry; if it persists, run `offsider doctor --device \(udid)`.\(RunnerSessionManager.logTail(logPath))",
            hint: "See \(logPath)"
        )
    }

    /// Polls the record's socket while its process lives, until the start deadline.
    private func awaitBroker(_ record: DeviceSessionRecord) async -> DeviceSessionClient? {
        let deadline = ContinuousClock.now + startTimeout
        while ContinuousClock.now < deadline, processes.isRunning(record) {
            if let client = await answering(record.socket, udid: record.udid, timeout: .seconds(1)) { return client }
            try? await Task.sleep(for: Self.pollInterval)
        }
        return nil
    }

    /// A client whose broker answered `ping` for this device and protocol.
    private func answering(_ socket: String, udid: String, timeout: Duration = DeviceSessionClient.pingTimeout) async -> DeviceSessionClient? {
        guard let link = try? connector(socket) else { return nil }
        let client = DeviceSessionClient(udid: udid, link: link)
        guard let reply = try? await client.ping(timeout: timeout),
              reply.protocol == DeviceSessionWire.protocolVersion,
              reply.udid?.caseInsensitiveCompare(udid) == .orderedSame else {
            link.close()
            return nil
        }
        return client
    }

    /// Asks the broker to stop (it ends the stream on the device first), signals it only while it is still the recorded process, then forgets it.
    public func stop(_ record: DeviceSessionRecord) async {
        if processes.isRunning(record), let identity = record.process {
            if let link = try? connector(record.socket) {
                try? await DeviceSessionClient(udid: record.udid, link: link).stop()
                link.close()
            }
            let deadline = ContinuousClock.now + .seconds(5)
            while processes.isRunning(record), ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(50))
            }
            if processes.isRunning(record) { processes.terminate(record.pid, identity: identity) }
        }
        store.remove(udid: record.udid)
    }

    /// Never starts a broker: a dead one reads as not alive, a live one is pinged.
    public func status(of record: DeviceSessionRecord) async -> DeviceSessionStatus {
        guard processes.isRunning(record) else { return DeviceSessionStatus(record: record, alive: false, reply: nil) }
        let client = await answering(record.socket, udid: record.udid)
        defer { client?.close() }
        return DeviceSessionStatus(record: record, alive: true, reply: client?.status)
    }

    /// `session.lock`, waited for while another command starts this device's broker.
    func acquireStartLock(udid: String) async throws -> IOSDeviceStartLock {
        try await IOSDeviceStartLock.acquire(try store.lockPath(udid: udid), timeout: lockTimeout, poll: Self.lockPollInterval) {
            IOSDeviceError(.sessionFailed, "Another Offsider command is still starting the device session for \(udid). Retry in a moment.")
        }
    }
}
