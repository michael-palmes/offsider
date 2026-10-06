import Foundation

/// One helper process per command: started on the first tree read, reused by every later read, stopped by `close()`.
@MainActor
final class HelperSession {
    static let helloTimeout: Duration = .seconds(2)
    static let dumpTimeout: Duration = .seconds(15)
    static let requestTimeout: Duration = .seconds(5)
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

    private let launcher: HelperLauncher
    private let log: AndroidLog
    private var connection: HelperConnection?
    private var nextID: Int
    private var restartedAfterLoss = false
    private var isClosed = false

    private init(launcher: HelperLauncher, connection: HelperConnection, nextID: Int, log: @escaping AndroidLog) {
        serial = launcher.serial
        ready = connection.ready
        launchMilliseconds = connection.launchMilliseconds
        pushed = connection.pushed
        helloMilliseconds = connection.helloMilliseconds
        ops = connection.ops
        self.launcher = launcher
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
        timing: AndroidTiming = .disabled
    ) async throws -> HelperSession {
        var launcher = HelperLauncher(client: client, serial: serial, dex: dex, log: log)
        launcher.timing = timing
        let connection = try await open(launcher, helloID: 1)
        return HelperSession(launcher: launcher, connection: connection, nextID: 2, log: log)
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
        let connection = HelperConnection(shell: shell, socket: opened, ready: ready)
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
        let dump = try await launcher.timing.measure(.helperDump) {
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

    /// Selects the focused field's text and pastes the clipboard over it; nil when this helper has no `paste` op.
    func paste() async throws -> HelperTextResult? {
        guard ops.contains("paste") else { return nil }
        return try await request(.paste, as: HelperTextResult.self, timeout: Self.requestTimeout)
    }

    /// Injects the steps; `extraWait` covers their pauses and swipes. Leaves the event cursor alone, so a verifier still wakes on the input's events.
    func inject(_ steps: [HelperValue], sync: Bool = true, extraWait: Duration) async throws -> HelperInjectReply {
        try await launcher.timing.measure(.helperInject) {
            try await request(.inject(steps, sync: sync), as: HelperInjectReply.self, timeout: Self.requestTimeout + extraWait)
        }
    }

    /// Display 0 as raw RGBA pixels from `UiAutomation.takeScreenshot`; an error reply throws `HelperErrorBody`.
    func screenshot() async throws -> AndroidScreenCapture.Pixels {
        let (reply, bytes) = try await launcher.timing.measure(.helperCapture) {
            try await requestWithPayload(.screenshot(format: "raw"), as: HelperScreenshotReply.self, timeout: Self.dumpTimeout)
        }
        let frame = reply.frame
        guard frame.format == "rgba8888", bytes.count == frame.bytes, frame.width > 0, frame.height > 0, bytes.count == frame.width * frame.height * 4 else {
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
            switch try await connection.exchange(request, id: id, timeout: timeout, expectingPayload: expectingPayload) {
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
            let fresh = try await Self.open(launcher, helloID: id)
            connection = fresh
            ready = fresh.ready
            launchMilliseconds = fresh.launchMilliseconds
            pushed = fresh.pushed
            helloMilliseconds = fresh.helloMilliseconds
            ops = fresh.ops
        } catch HelperStartFailure.unavailable(let reason) {
            throw AndroidError.helperCrashed(serial, detail: "it could not start again: \(reason)")
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

    /// `quit`; without an `ok` reply, the shell's exit, then `kill <pid>` when none came. A second call does nothing.
    func close() async {
        guard !isClosed else { return }
        isClosed = true
        guard connection != nil else { return }
        await launcher.timing.measure(.helperClose) {
            await shutdown()
        }
    }

    private func shutdown() async {
        guard let connection else { return }
        self.connection = nil
        let id = nextID
        nextID += 1
        // The helper frees the UiAutomation slot before it answers `quit`, then halts.
        if case .reply(let frame)? = try? await connection.exchange(.quit, id: id, timeout: Self.quitTimeout),
           (try? Self.decodeReply(frame, as: HelperEmpty.self)) != nil {
            await connection.close()
            return
        }
        let status = await connection.shell.exitStatus(deadline: ContinuousClock.now + Self.exitTimeout)
        await connection.close()
        guard status == nil else { return }
        let pid = connection.ready.pid
        log(.debug, "The UiAutomation helper on \(serial) (pid \(pid)) did not confirm its exit; killing it")
        _ = try? await launcher.client.shell("kill \(pid)", on: serial, timeout: Self.killTimeout)
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

    let shell: ShellStream
    let ready: HelperReady
    var launchMilliseconds = 0
    var pushed = false
    var helloMilliseconds = 0
    var ops: [String] = []
    private let socket: any AdbByteStream
    private var unread: Data
    private var decoder = HelperWire.FrameDecoder()
    private var frames: [Data] = []
    private var isClosed = false

    init(shell: ShellStream, socket: AdbServiceStream, ready: HelperReady) {
        self.shell = shell
        self.socket = socket.stream
        unread = socket.pending
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
        let deadline = ContinuousClock.now + timeout
        var reply: Data?
        let frame = try HelperWire.frame(try request.payload(id: id))
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
                    return .lost("its socket closed before it answered `\(request.op)`")
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
        await shell.close()
    }
}
