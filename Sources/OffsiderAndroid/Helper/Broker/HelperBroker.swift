import Darwin
import Foundation

/// Keeps one device's helper, its start shell and its one socket between commands, relaying their requests one at a time until it stops.
@MainActor
final class HelperBroker {
    struct Limits: Sendable {
        var idle: Duration
        var maxLifetime: Duration = HelperBrokerSettings.maxLifetime
        var healthInterval: Duration = .seconds(2)
        /// How long the helper has to answer a ping once its turn comes, however long the ping waited behind another command's request.
        var pingTimeout: Duration = HelperSession.requestTimeout
        var maxClients = 8
        /// Longer than any request a command sends, an inject's 60 s of gestures and its typing included; it bounds a request's own timeout.
        var relayTimeout: Duration = .seconds(120)
        /// How long a failed start waits for a command to read why, then for it to disconnect.
        var failureLinger: Duration = .seconds(3)
    }

    private enum State {
        case starting
        case ready(HelperSession)
        case failed(HelperStartFailure?, detail: String)
        case ended
    }

    let serial: String
    let socketPath: String
    let dexSha256: String
    let limits: Limits
    private let startHelper: @MainActor () async throws -> HelperSession
    private let admits: @Sendable (Int32) -> Bool
    private let log: AndroidLog
    private var state: State = .starting
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var lastRequest = ContinuousClock.now
    private var inFlight = 0
    private var clients = 0
    private var refusing = 0
    /// Clients past `hello`, so a command that reads another way does not stop a helper in use.
    private var attached = 0
    private var stopping = false
    private var helperGone: String?
    /// A command has read why the helper did not start.
    private var failureDelivered = false
    private var probeID = 1_000_000_000
    private let startedAt = Date()
    /// The display facts a command read from the shell, which hold while this helper runs on the same boot.
    private var screen: String?

    init(
        serial: String, socketPath: String, dexSha256: String, limits: Limits,
        startHelper: @escaping @MainActor () async throws -> HelperSession, admits: @escaping @Sendable (Int32) -> Bool, log: @escaping AndroidLog
    ) {
        self.serial = serial
        self.socketPath = socketPath
        self.dexSha256 = dexSha256
        self.limits = limits
        self.startHelper = startHelper
        self.admits = admits
        self.log = log
    }

    func requestStop() {
        stopping = true
    }

    /// Listens first, so the starting command can wait on `hello`, then starts the helper and serves until a reason to stop.
    func run() async throws {
        let listener = try UnixSocketListener(path: socketPath, admits: admits)
        log(.info, "Serving \(serial) on \(socketPath)")
        let started = ContinuousClock.now
        let accepting = Task { await acceptLoop(listener) }
        defer { accepting.cancel() }
        let session: HelperSession
        do {
            session = try await startHelper()
        } catch {
            let failure = error as? HelperStartFailure
            let detail = failure.map(String.init(describing:)) ?? ((error as? AndroidError)?.message ?? String(describing: error))
            log(.info, "Stopping: the helper did not start: \(detail)")
            state = .failed(failure, detail: detail)
            wake()
            let deadline = ContinuousClock.now + limits.failureLinger
            while !failureDelivered || clients > 0, ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(20))
            }
            listener.close()
            return
        }
        state = .ready(session)
        wake()
        log(.info, "The helper on \(serial) is ready (pid \(session.ready.pid), \(session.launchMilliseconds) ms)")
        lastRequest = .now
        var nextHealth = ContinuousClock.now + limits.healthInterval
        var idledOut = false
        while !stopping {
            try? await Task.sleep(for: .milliseconds(50))
            let now = ContinuousClock.now
            if let helperGone {
                log(.info, "Stopping: the helper has gone (\(helperGone))")
                break
            }
            guard inFlight == 0 else { continue }
            if now - lastRequest >= limits.idle {
                log(.info, "Stopping: idle for \(limits.idle)")
                idledOut = true
                break
            }
            if now - started >= limits.maxLifetime {
                log(.info, "Stopping: running for \(limits.maxLifetime); the next command starts a fresh broker")
                break
            }
            if now >= nextHealth {
                if let lost = await probe(session) {
                    log(.info, "Stopping: the helper did not answer ping (\(lost))")
                    break
                }
                nextHealth = ContinuousClock.now + limits.healthInterval
            }
        }
        state = .ended
        let drain = ContinuousClock.now + .seconds(5)
        while inFlight > 0, ContinuousClock.now < drain {
            try? await Task.sleep(for: .milliseconds(20))
        }
        let farewell = ContinuousClock.now + .seconds(2)
        while idledOut, clients > 0, ContinuousClock.now < farewell {
            try? await Task.sleep(for: .milliseconds(20))
        }
        // The socket goes last, so a command that waits for it to go knows the UiAutomation slot is free.
        await session.close()
        listener.close()
        log(.info, "Stopped")
    }

    // MARK: Clients

    /// A second short of the broker's own idle timeout, so a silent client always hears why it was let go.
    private var clientIdle: Duration {
        max(limits.idle - .seconds(1), limits.idle / 2)
    }

    private func acceptLoop(_ listener: UnixSocketListener) async {
        while !Task.isCancelled {
            guard let descriptor = await listener.accept(timeout: .milliseconds(100)) else { continue }
            let stream = PosixAdbStream.adopting(descriptor)
            guard clients < limits.maxClients else {
                // As many refusals as clients at once; past that a connection is closed unanswered, so a flood cannot pile up tasks.
                guard refusing < limits.maxClients else {
                    await stream.close()
                    continue
                }
                refusing += 1
                Task {
                    await refuse(stream)
                    refusing -= 1
                }
                continue
            }
            clients += 1
            Task {
                await serve(stream)
                clients -= 1
            }
        }
    }

    /// Reads the waiting request first, so the refusal answers its id, then closes.
    private func refuse(_ stream: PosixAdbStream) async {
        var decoder = HelperWire.FrameDecoder()
        let chunk = (try? await stream.read(upTo: 64 * 1024, deadline: .now + .seconds(2))) ?? Data()
        let id = (try? decoder.feed(chunk))?.first.flatMap(HelperBrokerWire.Request.parse)?.id ?? 0
        _ = await send([HelperBrokerWire.error(
            id: id, code: HelperBrokerWire.Code.refused,
            message: "the warm helper already serves \(limits.maxClients) commands at once; retry when one finishes"
        )], to: stream)
        await stream.close()
    }

    /// Reads requests until the client closes, stays silent for the idle timeout, or the helper goes; each reply is written before the next read.
    private func serve(_ stream: PosixAdbStream) async {
        var decoder = HelperWire.FrameDecoder()
        var frames: [Data] = []
        var isAttached = false
        defer {
            if isAttached { attached -= 1 }
            Task { await stream.close() }
        }
        while true {
            if frames.isEmpty {
                let chunk: Data
                do {
                    chunk = try await stream.read(upTo: 64 * 1024, deadline: .now + clientIdle)
                } catch AdbConnectError.timedOut {
                    // Said before the broker itself idles out, so a command that slept past it starts a fresh helper without counting a loss.
                    _ = await send([HelperBrokerWire.bye(reason: "idle", detail: "no request within \(clientIdle)")], to: stream)
                    return
                } catch {
                    return
                }
                guard !chunk.isEmpty, let decoded = try? decoder.feed(chunk) else { return }
                frames += decoded
                continue
            }
            let payload = frames.removeFirst()
            guard payload.count <= HelperBrokerWire.maxRequestBytes, let request = HelperBrokerWire.Request.parse(payload) else {
                _ = await send([HelperBrokerWire.error(id: 0, code: HelperBrokerWire.Code.badRequest, message: "the request is not a helper request")], to: stream)
                return
            }
            guard let replies = await answer(request, payload: payload, from: stream), await send(replies, to: stream) else { return }
            if request.op == "hello", !isAttached, replies.first.map(HelperBrokerWire.isOK) == true {
                isAttached = true
                attached += 1
            }
            if helperGone != nil { return }
        }
    }

    /// The frames to send back, nil to close without a reply (input whose command has already gone).
    private func answer(_ request: HelperBrokerWire.Request, payload: Data, from stream: PosixAdbStream) async -> [Data]? {
        switch request.op {
        case "status":
            return [HelperBrokerWire.statusReply(id: request.id, status())]
        case "stop":
            stopping = true
            guard case .starting = state else { return [HelperBrokerWire.ok(id: request.id)] }
            return [HelperBrokerWire.ok(id: request.id, fields: ["starting": .bool(true)])]
        case "health":
            guard case .ready(let session) = state, !stopping, helperGone == nil else {
                return [HelperBrokerWire.error(id: request.id, code: HelperBrokerWire.Code.ended, message: "the warm helper is not ready")]
            }
            // A command's request on the helper shows it working, and a ping would wait behind it.
            guard inFlight == 0 else { return [HelperBrokerWire.ok(id: request.id, fields: ["busy": .bool(true)])] }
            let started = ContinuousClock.now
            if let lost = await probe(session) {
                return [HelperBrokerWire.error(id: request.id, code: HelperBrokerWire.Code.ended, message: "the warm helper did not answer ping (\(lost))")]
            }
            return [HelperBrokerWire.ok(id: request.id, fields: ["pingMs": .int(HelperLauncher.milliseconds(since: started))])]
        case "screen":
            guard case .ready = state, !stopping, helperGone == nil, let screen else { return [HelperBrokerWire.ok(id: request.id)] }
            return [HelperBrokerWire.ok(id: request.id, fields: ["screen": .string(screen)])]
        case "rememberScreen":
            screen = request.screen
            return [HelperBrokerWire.ok(id: request.id)]
        case "quit":
            return [HelperBrokerWire.error(id: request.id, code: HelperBrokerWire.Code.refused, message: "the warm helper stops by itself; `offsider session stop` stops it now")]
        case "hello":
            await untilStarted()
            return [await hello(request.id)]
        default:
            guard case .ready(let session) = state, !stopping else {
                return [HelperBrokerWire.bye(reason: "broker-ended", detail: "the warm helper is stopping")]
            }
            inFlight += 1
            lastRequest = .now
            defer {
                inFlight -= 1
                lastRequest = .now
            }
            return await relay(request, payload: payload, through: session, from: stream)
        }
    }

    /// Why a request is not sent once its turn on the helper comes.
    enum Unsent: Equatable, Sendable {
        /// Input whose command has gone: closed without a reply.
        case gone
        /// Its command has given up, or it is input that waited so long it could land after its command gave up.
        case late(waited: Duration)
    }

    /// A command gives input `requestTimeout` beyond its gesture; input that waited all but 1 s of that for its turn is dropped unsent.
    nonisolated static let staleInputAge: Duration = HelperSession.requestTimeout - .seconds(1)
    /// A request whose turn came with less time left still gets this long, so a late turn never makes a healthy helper look wedged.
    nonisolated static let minimumReplyWait: Duration = .seconds(1)

    nonisolated static func unsent(op: String, peerClosed: Bool, waited: Duration, timeout: Duration) -> Unsent? {
        if op == "inject", peerClosed { return .gone }
        if waited >= timeout || (op == "inject" && waited > staleInputAge) { return .late(waited: waited) }
        return nil
    }

    /// The command's timeout counts from the request's arrival, as the command's own does, so time spent behind another command's request is part of it.
    private func relay(
        _ request: HelperBrokerWire.Request, payload: Data, through session: HelperSession, from stream: PosixAdbStream
    ) async -> [Data]? {
        let arrival = ContinuousClock.now
        let timeout = Self.relayTimeout(for: request, cap: limits.relayTimeout)
        var unsent: Unsent?
        let outcome: HelperConnection.Outcome?
        do {
            outcome = try await session.relay(
                payload: payload, op: request.op, id: request.id, deadline: arrival + timeout, atLeast: Self.minimumReplyWait
            ) {
                unsent = Self.unsent(op: request.op, peerClosed: stream.peerClosed(), waited: .now - arrival, timeout: timeout)
                return unsent != nil
            }
        } catch {
            outcome = .lost(String(describing: error))
        }
        guard let outcome else {
            guard case .late(let waited)? = unsent else { return nil }
            let seconds = (waited / .milliseconds(100)).rounded() / 10
            log(.debug, "Dropped `\(request.op)` unsent after it waited \(seconds) s for the helper")
            return [HelperBrokerWire.error(
                id: request.id, code: HelperBrokerWire.Code.refused,
                message: "the warm helper was busy with another command for \(seconds) s, so this \(request.op == "inject" ? "input" : "request") was not sent; retry"
            )]
        }
        switch outcome {
        case .reply(let frame):
            return [frame]
        case .replyWithPayload(let frame, let bytes):
            return [frame, bytes]
        case .bye(let reason, let detail):
            helperGone = "it ended with \(reason)"
            return [HelperBrokerWire.bye(reason: reason, detail: detail)]
        case .lost(let detail):
            helperGone = detail
            return [HelperBrokerWire.bye(reason: "lost", detail: detail)]
        case .timedOut:
            helperGone = "no reply to `\(request.op)` within \(timeout)"
            return [HelperBrokerWire.bye(reason: "timeout", detail: helperGone)]
        }
    }

    /// The command's own timeout, so a helper it gave up on ends here too and the next command starts afresh; a request without one gets the cap.
    nonisolated static func relayTimeout(for request: HelperBrokerWire.Request, cap: Duration) -> Duration {
        if let milliseconds = request.brokerTimeoutMs, milliseconds > 0 {
            return min(.milliseconds(milliseconds), cap)
        }
        return request.op == "events" ? .milliseconds(min(max(request.waitMs ?? 0, 0), 5000)) + .seconds(5) : cap
    }

    private func hello(_ id: Int) async -> Data {
        switch state {
        case .starting, .ended:
            return HelperBrokerWire.error(id: id, code: HelperBrokerWire.Code.ended, message: "the warm helper is stopping")
        case .failed(let failure?, _):
            failureDelivered = true
            return HelperBrokerWire.startFailure(id: id, failure)
        case .failed(nil, let detail):
            failureDelivered = true
            return HelperBrokerWire.error(id: id, code: HelperBrokerWire.Code.startFailed, message: detail)
        case .ready(let session):
            guard !stopping else {
                return HelperBrokerWire.error(id: id, code: HelperBrokerWire.Code.ended, message: "the warm helper is stopping")
            }
            inFlight += 1
            lastRequest = .now
            defer {
                inFlight -= 1
                lastRequest = .now
            }
            guard let seq = await latestEventSeq(session) else {
                return HelperBrokerWire.error(id: id, code: HelperBrokerWire.Code.ended, message: "the warm helper did not answer")
            }
            return HelperBrokerWire.helloReply(
                id: id, helper: session.ready.helper, protocol: session.ready.protocol, ops: session.ops,
                broker: HelperBrokerWire.Hello(
                    brokerProtocol: HelperBrokerWire.protocolVersion, brokerPid: getpid(), dexSha256: dexSha256,
                    helperPid: session.ready.pid, sdkInt: session.ready.sdkInt, idleSeconds: Int(limits.idle.components.seconds),
                    launchMs: session.launchMilliseconds, pushed: session.pushed, eventSeq: seq, attached: attached
                )
            )
        }
    }

    private func status() -> HelperBrokerWire.Status {
        let session: HelperSession?
        let state: HelperBrokerWire.Status.State
        switch self.state {
        case .starting:
            (session, state) = (nil, .starting)
        case .ready(let running):
            (session, state) = (running, stopping ? .stopping : .ready)
        case .failed, .ended:
            (session, state) = (nil, .stopping)
        }
        return HelperBrokerWire.Status(
            serial: serial, state: state, brokerPid: getpid(), helperPid: session?.ready.pid, startedAt: startedAt.timeIntervalSince1970,
            idleSeconds: Int(limits.idle.components.seconds), idleFor: Int((ContinuousClock.now - lastRequest).components.seconds),
            attached: attached, helper: session?.ready.helper, protocol: session?.ready.protocol, sdkInt: session?.ready.sdkInt,
            launchMs: session?.launchMilliseconds, pushed: session?.pushed
        )
    }

    private func send(_ frames: [Data], to stream: PosixAdbStream) async -> Bool {
        do {
            for frame in frames {
                try await stream.write(try HelperWire.frame(frame), deadline: .now + .seconds(10))
            }
            return true
        } catch {
            return false
        }
    }

    // MARK: Helper

    /// The helper's latest event number from a `ping`, nil when it did not answer.
    private func latestEventSeq(_ session: HelperSession) async -> Int64? {
        probeID += 1
        let ping = (try? HelperRequest.ping.payload(id: probeID)) ?? Data()
        let outcome = try? await session.relay(payload: ping, op: "ping", id: probeID, deadline: .now, atLeast: limits.pingTimeout)
        guard case .reply(let frame)? = outcome, let envelope = try? JSONDecoder().decode(HelperEnvelope.self, from: frame), envelope.ok == true else {
            if helperGone == nil { helperGone = "it did not answer ping" }
            return nil
        }
        return envelope.eventSeq ?? 0
    }

    /// Why the helper failed a ping, or nil when it answered; a ping does not count as use.
    private func probe(_ session: HelperSession) async -> String? {
        await latestEventSeq(session) == nil ? (helperGone ?? "no reply") : nil
    }

    private func untilStarted() async {
        guard case .starting = state else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func wake() {
        let waiting = waiters
        waiters = []
        waiting.forEach { $0.resume() }
    }
}
