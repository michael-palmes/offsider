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

    private let launcher: HelperLauncher
    private let log: AndroidLog
    private var connection: HelperConnection?
    private var nextID: Int
    private var restartedAfterLoss = false
    private var isClosed = false

    private init(launcher: HelperLauncher, connection: HelperConnection, nextID: Int, log: @escaping AndroidLog) {
        serial = launcher.serial
        ready = connection.ready
        self.launcher = launcher
        self.connection = connection
        self.nextID = nextID
        self.log = log
    }

    /// Launch, open `localabstract:<socket>`, send `hello` with the token; throws `HelperStartFailure` or a device error.
    static func start(client: AdbClient, serial: String, dex: HelperDex, log: @escaping AndroidLog) async throws -> HelperSession {
        let launcher = HelperLauncher(client: client, serial: serial, dex: dex, log: log)
        let connection = try await open(launcher, helloID: 1)
        return HelperSession(launcher: launcher, connection: connection, nextID: 2, log: log)
    }

    private static func open(_ launcher: HelperLauncher, helloID: Int) async throws -> HelperConnection {
        let (shell, ready) = try await launcher.launch()
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
        let dump = try await screenRequest(.dump(options), as: HelperDump.self, timeout: Self.dumpTimeout)
        display = dump.display
        windows = dump.windows
        eventCursor = dump.eventSeq
        return dump
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

    private func screenRequest<Reply: Decodable>(_ request: HelperRequest, as type: Reply.Type, timeout: Duration) async throws -> Reply {
        do {
            return try await self.request(request, as: type, timeout: timeout)
        } catch let error as HelperErrorBody {
            throw AndroidError.helperFailed(serial, message: error.message)
        } catch let error as HelperProtocolError {
            throw AndroidError.helperFailed(serial, message: error.detail)
        }
    }

    /// An error reply throws `HelperErrorBody`; an idle `bye` restarts and resends each time; a lost helper restarts once.
    func request<Reply: Decodable>(_ request: HelperRequest, as type: Reply.Type, timeout: Duration) async throws -> Reply {
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
            switch try await connection.exchange(request, id: id, timeout: timeout) {
            case .reply(let frame):
                return try Self.decodeReply(frame, as: type)
            case .bye(let reason, let detail) where reason == "idle":
                log(.debug, "The UiAutomation helper on \(serial) left after idling (\(detail ?? "no detail")); starting it again")
                await drop(connection)
                try await restart()
            case .bye(let reason, let detail):
                try await recover(connection, from: "it ended with \(reason)\(detail.map { ": \($0)" } ?? "")")
            case .lost(let detail):
                try await recover(connection, from: detail)
            case .timedOut:
                await shutdown()
                throw AndroidError.helperTimedOut(serial, op: request.op, seconds: Int(timeout.components.seconds))
            }
        }
    }

    private func recover(_ lost: HelperConnection, from detail: String) async throws {
        await drop(lost)
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

    /// `quit`, then the shell's exit; `kill <pid>` only when no exit was seen. A second call does nothing.
    func close() async {
        guard !isClosed else { return }
        isClosed = true
        await shutdown()
    }

    private func shutdown() async {
        guard let connection else { return }
        self.connection = nil
        let id = nextID
        nextID += 1
        _ = try? await connection.exchange(.quit, id: id, timeout: Self.quitTimeout)
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
        case bye(reason: String, detail: String?)
        case lost(String)
        case timedOut
    }

    let shell: ShellStream
    let ready: HelperReady
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
            return
        case .bye(let reason, _): detail = "it ended with \(reason) before answering hello"
        case .lost(let lost): detail = lost
        case .timedOut: detail = "no reply to hello within \(HelperSession.helloTimeout.components.seconds) s"
        }
        throw HelperStartFailure.unavailable(.handshake(detail))
    }

    /// Sends one request and reads frames until its reply or a `bye`; never throws for a lost or silent helper.
    func exchange(_ request: HelperRequest, id: Int, timeout: Duration) async throws -> Outcome {
        let deadline = ContinuousClock.now + timeout
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
                guard let envelope = try? JSONDecoder().decode(HelperEnvelope.self, from: payload) else {
                    return .lost("it sent a frame Offsider could not read")
                }
                if envelope.event == "bye" {
                    return .bye(reason: envelope.reason ?? "unknown", detail: envelope.detail)
                }
                if envelope.id == id {
                    return .reply(payload)
                }
            }
            var chunk = unread
            unread = Data()
            if chunk.isEmpty {
                do {
                    chunk = try await socket.read(upTo: 64 * 1024, deadline: deadline)
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
