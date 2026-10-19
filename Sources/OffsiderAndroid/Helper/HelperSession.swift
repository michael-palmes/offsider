import Foundation
import OffsiderCore

/// Where a session's helper comes from: one started for this command, or the warm helper a broker keeps between commands.
@MainActor
enum HelperOrigin {
    case launched(HelperLauncher)
    case brokered(HelperBrokerClient)

    var timing: AndroidTiming {
        switch self {
        case .launched(let launcher): return launcher.timing
        case .brokered(let broker): return broker.timing
        }
    }
}

/// One helper per command, or a connection to the warm one: opened on the first tree read, reused by every later read, released by `close()`.
@MainActor
final class HelperSession {
    static let helloTimeout: Duration = .seconds(2)
    static let dumpTimeout: Duration = .seconds(15)
    nonisolated static let requestTimeout: Duration = .seconds(5)
    static let quitTimeout: Duration = .milliseconds(500)
    static let exitTimeout: Duration = .seconds(1)
    static let killTimeout: Duration = .seconds(2)

    let serial: String
    private(set) var ready: HelperReady
    private(set) var display: HelperDisplay?
    private(set) var windows: [HelperWindow] = []
    /// The latest dump's `eventSeq`: events after it are changes since Offsider last read the tree.
    private(set) var eventCursor: Int64 = 0
    /// The latest mapped dump's nodes and references, for actions on what the command last saw.
    private(set) var index: HelperTreeIndex?
    /// From the latest start: time to the ready line (with any push), whether the dex was pushed, and the `hello` time.
    private(set) var launchMilliseconds: Int
    private(set) var pushed: Bool
    private(set) var helloMilliseconds: Int
    /// The ops the running helper listed in `hello`.
    private(set) var ops: [String]

    private let origin: HelperOrigin
    private let log: AndroidLog
    private var connection: HelperConnection?
    private var nextID: Int
    private var restartedAfterLoss = false
    private var isClosed = false
    /// One request on the socket at a time, in the order they came, so a capture and a tree read running together never interleave frames.
    private let queue = HelperRequestQueue()

    private var timing: AndroidTiming { origin.timing }

    /// True when the helper is the broker's warm one, which outlives this command.
    var isWarm: Bool {
        if case .brokered = origin { return true }
        return false
    }

    private init(origin: HelperOrigin, serial: String, connection: HelperConnection, nextID: Int, log: @escaping AndroidLog) {
        self.serial = serial
        ready = connection.ready
        launchMilliseconds = connection.launchMilliseconds
        pushed = connection.pushed
        helloMilliseconds = connection.helloMilliseconds
        ops = connection.ops
        eventCursor = connection.eventSeq ?? 0
        self.origin = origin
        self.connection = connection
        self.nextID = nextID
        self.log = log
    }

    /// Launch, open `localabstract:<socket>`, send `hello` with the token; throws `HelperStartFailure` or a device error.
    static func start(
        client: AdbClient,
        serial: String,
        dex: HelperDex,
        log: @escaping AndroidLog,
        timing: AndroidTiming = .disabled,
        idleTimeoutMs: Int = HelperLauncher.idleTimeoutMs
    ) async throws -> HelperSession {
        var launcher = HelperLauncher(client: client, serial: serial, dex: dex, log: log)
        launcher.timing = timing
        launcher.idleTimeoutMs = idleTimeoutMs
        let connection = try await open(launcher, helloID: 1)
        return HelperSession(origin: .launched(launcher), serial: serial, connection: connection, nextID: 2, log: log)
    }

    /// Connects to the broker's warm helper, starting the broker when none serves `serial`; throws `HelperStartFailure` as `start` does.
    static func attach(_ broker: HelperBrokerClient, log: @escaping AndroidLog) async throws -> HelperSession {
        let connection = try await broker.connect(helloID: 1)
        return HelperSession(origin: .brokered(broker), serial: broker.serial, connection: connection, nextID: 2, log: log)
    }

    private static func open(_ origin: HelperOrigin, helloID: Int) async throws -> HelperConnection {
        switch origin {
        case .launched(let launcher): return try await open(launcher, helloID: helloID)
        case .brokered(let broker): return try await broker.connect(helloID: helloID)
        }
    }

    private static func open(_ launcher: HelperLauncher, helloID: Int) async throws -> HelperConnection {
        let (shell, ready, pushed, launchMilliseconds) = try await launcher.launch()
        let helloStart = ContinuousClock.now
        return try await launcher.timing.measure(.helperHello) {
            let connection = try await hello(launcher, shell: shell, ready: ready, helloID: helloID)
            connection.launchMilliseconds = launchMilliseconds
            connection.pushed = pushed
            connection.helloMilliseconds = HelperLauncher.milliseconds(since: helloStart)
            return connection
        }
    }

    private static func hello(_ launcher: HelperLauncher, shell: ShellStream, ready: HelperReady, helloID: Int) async throws -> HelperConnection {
        let opened: AdbServiceStream
        do {
            opened = try await launcher.client.openService("localabstract:" + ready.socket, on: launcher.serial, timeout: helloTimeout)
        } catch let error as AndroidError where error.kind == .adbCommandFailed {
            await shell.close()
            throw HelperStartFailure.unavailable(.handshake(error.message))
        } catch {
            await shell.close()
            throw error
        }
        let connection = HelperConnection(shell: shell, socket: opened.stream, pending: opened.pending, ready: ready)
        do {
            try await connection.hello(id: helloID)
        } catch {
            await connection.close()
            throw error
        }
        return connection
    }

    func ping() async throws {
        _ = try await request(.ping, as: HelperEmpty.self, timeout: Self.requestTimeout)
    }

    func dump(_ options: HelperDumpOptions = HelperDumpOptions()) async throws -> HelperDump {
        let dump = try await timing.measure(.helperDump) {
            try await screenRequest(.dump(options), as: HelperDump.self, timeout: Self.dumpTimeout)
        }
        display = dump.display
        windows = dump.windows
        eventCursor = dump.eventSeq
        return dump
    }

    /// The dump reply as JSON, for the committed tree goldens.
    func rawDump() async throws -> Data {
        let reply = try await screenRequest(.dump(HelperDumpOptions()), as: HelperRawJSON.self, timeout: Self.dumpTimeout)
        guard var object = reply.value as? [String: Any] else {
            throw AndroidError.helperFailed(serial, message: "its dump reply was not an object")
        }
        object["id"] = nil
        object["ok"] = nil
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    func remember(_ index: HelperTreeIndex) {
        self.index = index
    }

    /// The `display` op: the display and the window list, without trees.
    func refreshDisplay() async throws -> HelperDisplay {
        let reply = try await screenRequest(.display, as: HelperDisplayReply.self, timeout: Self.requestTimeout)
        display = reply.display
        windows = reply.windows
        return reply.display
    }

    /// `ACTION_SET_PROGRESS` on a node of the latest dump; an error reply throws `HelperErrorBody`.
    func setProgress(_ node: HelperNodeRef, value: Double, expecting range: HelperRange) async throws -> HelperProgressResult {
        try await request(.setProgress(node, value: value, expecting: range), as: HelperProgressResult.self, timeout: Self.requestTimeout)
    }

    /// Events after the cursor (the latest dump, or the last event returned), waiting up to `timeout`; advances the cursor.
    func events(waitingUpTo timeout: Duration) async throws -> [HelperEvent] {
        let waitMs = max(0, Int((timeout / .milliseconds(1)).rounded()))
        let reply = try await request(.events(since: eventCursor, waitMs: waitMs), as: HelperEvents.self, timeout: timeout + .seconds(2))
        if let last = reply.events.last {
            eventCursor = max(eventCursor, last.seq)
        }
        return reply.events
    }

    /// `ACTION_SET_TEXT` on the field with input focus; an error reply throws `HelperErrorBody`.
    func setText(_ text: String) async throws -> HelperTextResult {
        try await request(.setText(text), as: HelperTextResult.self, timeout: Self.requestTimeout)
    }

    /// Pastes the clipboard over all of the focused field's text, only into `field` when given; nil when this helper has no `paste` op.
    func paste(expecting field: AndroidFieldInfo?) async throws -> HelperTextResult? {
        guard ops.contains("paste") else { return nil }
        return try await request(.paste(expecting: field), as: HelperTextResult.self, timeout: Self.requestTimeout)
    }

    /// Injects the steps; `extraWait` covers their pauses and swipes. Leaves the event cursor alone, so a verifier still wakes on the input's events.
    func inject(_ steps: [HelperValue], sync: Bool = true, extraWait: Duration) async throws -> HelperInjectReply {
        try await timing.measure(.helperInject) {
            try await request(.inject(steps, sync: sync), as: HelperInjectReply.self, timeout: Self.requestTimeout + extraWait)
        }
    }

    /// Display 0 as raw RGBA pixels from `UiAutomation.takeScreenshot`; an error reply throws `HelperErrorBody`.
    func screenshot() async throws -> AndroidScreenCapture.Pixels {
        let (reply, bytes) = try await timing.measure(.helperCapture) {
            try await requestWithPayload(.screenshot(format: "raw"), as: HelperScreenshotReply.self, timeout: Self.dumpTimeout)
        }
        let frame = reply.frame
        guard frame.format == "rgba8888", bytes.count == frame.bytes, let expected = PixelMath.byteCount(width: frame.width, height: frame.height), bytes.count == expected else {
            throw HelperProtocolError(detail: "its screenshot frame (\(frame.format), \(frame.width) x \(frame.height), \(bytes.count) bytes) does not match its header")
        }
        return AndroidScreenCapture.Pixels(width: frame.width, height: frame.height, bytes: bytes)
    }

    private func screenRequest<Reply: Decodable>(_ request: HelperRequest, as type: Reply.Type, timeout: Duration) async throws -> Reply {
        do {
            return try await self.request(request, as: type, timeout: timeout)
        } catch let error as HelperErrorBody {
            throw AndroidError.helperFailed(serial, message: error.message)
        } catch let error as HelperProtocolError {
            throw AndroidError.helperFailed(serial, message: error.detail)
        }
    }

    /// An error reply throws `HelperErrorBody`; an idle `bye` restarts and resends each time; a lost helper restarts once, except under `inject`.
    func request<Reply: Decodable>(_ request: HelperRequest, as type: Reply.Type, timeout: Duration) async throws -> Reply {
        try Self.decodeReply(try await send(request, timeout: timeout, expectingPayload: false).reply, as: type)
    }

    /// As `request`, for an op whose successful reply is followed by one binary frame.
    func requestWithPayload<Reply: Decodable>(_ request: HelperRequest, as type: Reply.Type, timeout: Duration) async throws -> (Reply, Data) {
        let (frame, payload) = try await send(request, timeout: timeout, expectingPayload: true)
        let reply = try Self.decodeReply(frame, as: type)
        guard let payload else {
            throw HelperProtocolError(detail: "its `\(request.op)` reply came without its frame")
        }
        return (reply, payload)
    }

    private func send(_ request: HelperRequest, timeout: Duration, expectingPayload: Bool) async throws -> (reply: Data, payload: Data?) {
        await queue.acquire()
        defer { queue.release() }
        while true {
            guard !isClosed else {
                throw AndroidError.helperCrashed(serial, detail: "Offsider had already stopped it")
            }
            guard let connection else {
                try await restart()
                continue
            }
            let id = nextID
            nextID += 1
            let outgoing = isWarm ? request.adding(HelperBrokerWire.timeoutField, .int(Int(timeout / .milliseconds(1)))) : request
            switch try await connection.exchange(outgoing, id: id, timeout: timeout, expectingPayload: expectingPayload) {
            case .reply(let frame):
                return (frame, nil)
            case .replyWithPayload(let frame, let payload):
                return (frame, payload)
            case .bye(let reason, let detail) where reason == "idle":
                log(.debug, "The UiAutomation helper on \(serial) left after idling (\(detail ?? "no detail")); starting it again")
                await drop(connection)
                try await restart()
            case .bye(let reason, let detail):
                try await recover(connection, from: "it ended with \(reason)\(detail.map { ": \($0)" } ?? "")", resending: request)
            case .lost(let detail):
                try await recover(connection, from: detail, resending: request)
            case .timedOut:
                await shutdown()
                throw AndroidError.helperTimedOut(serial, op: request.op, seconds: Int(timeout.components.seconds))
            }
        }
    }

    /// A broker's relay of a command's request, waiting until `deadline` but `atLeast` once sent; nil, unsent, when `skip` says so on its turn.
    func relay(
        payload: Data, op: String, id: Int, deadline: ContinuousClock.Instant, atLeast minimum: Duration = .zero, skip: () -> Bool = { false }
    ) async throws -> HelperConnection.Outcome? {
        await queue.acquire()
        defer { queue.release() }
        guard !skip() else { return nil }
        guard !isClosed, let connection else { return .lost("the warm helper has stopped") }
        let outcome = try await connection.exchange(
            payload: payload, op: op, id: id, timeout: max(deadline - .now, minimum), expectingPayload: op == "screenshot"
        )
        switch outcome {
        case .reply, .replyWithPayload: break
        case .bye, .lost, .timedOut: await drop(connection)
        }
        return outcome
    }

    /// An `inject` may have reached the device before the helper went, so it is never sent again; a later request restarts the helper.
    private func recover(_ lost: HelperConnection, from detail: String, resending request: HelperRequest) async throws {
        await drop(lost)
        guard request.op != "inject" else {
            throw AndroidError.helperLostInput(serial, detail: detail)
        }
        guard !restartedAfterLoss else {
            throw AndroidError.helperCrashed(serial, detail: detail)
        }
        restartedAfterLoss = true
        log(.debug, "The UiAutomation helper on \(serial) was lost (\(detail)); starting it again")
        try await restart()
    }

    private func restart() async throws {
        let id = nextID
        nextID += 1
        do {
            let fresh = try await Self.open(origin, helloID: id)
            connection = fresh
            ready = fresh.ready
            launchMilliseconds = fresh.launchMilliseconds
            pushed = fresh.pushed
            helloMilliseconds = fresh.helloMilliseconds
            ops = fresh.ops
            if let seq = fresh.eventSeq { eventCursor = seq }
        } catch HelperStartFailure.unavailable(let reason) {
            throw AndroidError.helperCrashed(serial, detail: "it could not start again: \(reason)")
        } catch let error as HelperBrokerUnavailable {
            throw AndroidError.helperCrashed(serial, detail: "it could not start again: \(error.detail)")
        }
    }

    private func drop(_ old: HelperConnection) async {
        if connection === old {
            connection = nil
        }
        await old.close()
    }

    private static func decodeReply<Reply: Decodable>(_ frame: Data, as type: Reply.Type) throws -> Reply {
        let envelope: HelperEnvelope
        do {
            envelope = try JSONDecoder().decode(HelperEnvelope.self, from: frame)
        } catch {
            throw HelperProtocolError(detail: "its reply was unreadable")
        }
        guard envelope.ok == true else {
            throw envelope.error ?? HelperErrorBody(code: "unknown", message: "it failed without saying why", detail: nil, className: nil, resourceId: nil)
        }
        do {
            return try JSONDecoder().decode(type, from: frame)
        } catch {
            throw HelperProtocolError(detail: "its reply was unreadable: \(error.localizedDescription)")
        }
    }

    /// `quit`; without an `ok` reply, the shell's exit, then `kill <pid>` when none came. A warm helper is left to its broker. A second call does nothing.
    func close() async {
        guard !isClosed else { return }
        isClosed = true
        guard connection != nil else { return }
        await timing.measure(.helperClose) {
            await shutdown()
        }
    }

    private func shutdown() async {
        guard let connection else { return }
        self.connection = nil
        guard case .launched(let launcher) = origin else {
            await connection.close()
            return
        }
        let id = nextID
        nextID += 1
        // The helper frees the UiAutomation slot before it answers `quit`, then halts.
        if case .reply(let frame)? = try? await connection.exchange(.quit, id: id, timeout: Self.quitTimeout),
           (try? Self.decodeReply(frame, as: HelperEmpty.self)) != nil {
            await connection.close()
            return
        }
        let status = await connection.shell?.exitStatus(deadline: ContinuousClock.now + Self.exitTimeout)
        await connection.close()
        guard status == nil else { return }
        let pid = connection.ready.pid
        log(.debug, "The UiAutomation helper on \(serial) (pid \(pid)) did not confirm its exit; killing it")
        _ = try? await launcher.client.shell("kill \(pid)", on: serial, timeout: Self.killTimeout)
    }
}

/// A first-come, first-served lock for requests on one helper socket.
@MainActor
final class HelperRequestQueue {
    private var busy = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        guard busy else {
            busy = true
            return
        }
        await withCheckedContinuation { waiting.append($0) }
    }

    /// Hands the lock straight to the longest waiter, so a newcomer cannot jump the queue.
    func release() {
        if waiting.isEmpty {
            busy = false
        } else {
            waiting.removeFirst().resume()
        }
    }
}

/// Replies with no fields of their own (`ping`, `quit`).
struct HelperEmpty: Decodable, Sendable {}

/// One helper process: its open start shell and its socket.
@MainActor
final class HelperConnection {
    enum Outcome: Equatable {
        case reply(Data)
        case replyWithPayload(Data, Data)
        case bye(reason: String, detail: String?)
        case lost(String)
        case timedOut
    }

    /// The start shell of a helper this command launched; nil for a broker's warm helper.
    let shell: ShellStream?
    private(set) var ready: HelperReady
    var launchMilliseconds = 0
    var pushed = false
    var helloMilliseconds = 0
    var ops: [String] = []
    /// The helper's event sequence number when a broker's connection opened, so events from earlier commands are not taken as new.
    var eventSeq: Int64?
    private let socket: any AdbByteStream
    private var unread: Data
    private var decoder = HelperWire.FrameDecoder()
    private var frames: [Data] = []
    private var isClosed = false

    init(shell: ShellStream?, socket: any AdbByteStream, pending: Data = Data(), ready: HelperReady) {
        self.shell = shell
        self.socket = socket
        unread = pending
        self.ready = ready
    }

    /// What a broker's `hello` said of its warm helper, which no ready line reached this command for.
    func adopt(_ ready: HelperReady) {
        self.ready = ready
    }

    /// The first frame must be `hello` with the ready line's token, answered with this Offsider's protocol.
    func hello(id: Int) async throws {
        let outcome = try await exchange(.hello(token: ready.token), id: id, timeout: HelperSession.helloTimeout)
        let detail: String
        switch outcome {
        case .reply(let frame):
            guard let envelope = try? JSONDecoder().decode(HelperEnvelope.self, from: frame) else {
                throw HelperStartFailure.unavailable(.handshake("its hello reply was unreadable"))
            }
            guard envelope.ok == true, let hello = try? JSONDecoder().decode(HelperHello.self, from: frame) else {
                throw HelperStartFailure.unavailable(.handshake(envelope.error?.message ?? "it refused hello"))
            }
            guard hello.protocol == HelperDex.protocolVersion else {
                throw HelperStartFailure.unavailable(.handshake(
                    "the helper on the device speaks protocol \(hello.protocol), Offsider speaks \(HelperDex.protocolVersion)"
                ))
            }
            ops = hello.ops ?? []
            return
        case .replyWithPayload: detail = "it answered hello with a frame it never announced"
        case .bye(let reason, _): detail = "it ended with \(reason) before answering hello"
        case .lost(let lost): detail = lost
        case .timedOut: detail = "no reply to hello within \(HelperSession.helloTimeout.components.seconds) s"
        }
        throw HelperStartFailure.unavailable(.handshake(detail))
    }

    /// One request, then frames until its reply (and its binary frame when `expectingPayload`) or a `bye`; a lost or silent helper never throws.
    func exchange(_ request: HelperRequest, id: Int, timeout: Duration, expectingPayload: Bool = false) async throws -> Outcome {
        try await exchange(payload: try request.payload(id: id), op: request.op, id: id, timeout: timeout, expectingPayload: expectingPayload)
    }

    /// As `exchange`, for a request already encoded, as the broker passes a command's frame on.
    func exchange(payload: Data, op: String, id: Int, timeout: Duration, expectingPayload: Bool = false) async throws -> Outcome {
        let deadline = ContinuousClock.now + timeout
        var reply: Data?
        let frame = try HelperWire.frame(payload)
        do {
            try await socket.write(frame, deadline: deadline)
        } catch AdbConnectError.timedOut {
            return .timedOut
        } catch {
            // The helper may have said goodbye before the write failed, so read what it sent.
        }
        while true {
            while !frames.isEmpty {
                let payload = frames.removeFirst()
                if let reply {
                    return .replyWithPayload(reply, payload)
                }
                guard let envelope = try? JSONDecoder().decode(HelperEnvelope.self, from: payload) else {
                    return .lost("it sent a frame Offsider could not read")
                }
                if envelope.event == "bye" {
                    return .bye(reason: envelope.reason ?? "unknown", detail: envelope.detail)
                }
                if envelope.id == id {
                    guard expectingPayload, envelope.ok == true else { return .reply(payload) }
                    reply = payload
                }
            }
            var chunk = unread
            unread = Data()
            if chunk.isEmpty {
                do {
                    chunk = try await socket.read(upTo: reply == nil ? 64 * 1024 : 1 << 20, deadline: deadline)
                } catch AdbConnectError.timedOut {
                    return .timedOut
                } catch {
                    return .lost("reading its socket failed")
                }
                if chunk.isEmpty {
                    return .lost("its socket closed before it answered `\(op)`")
                }
            }
            do {
                frames += try decoder.feed(chunk)
            } catch let error as HelperProtocolError {
                return .lost(error.detail)
            }
        }
    }

    func close() async {
        guard !isClosed else { return }
        isClosed = true
        await socket.close()
        await shell?.close()
    }
}
