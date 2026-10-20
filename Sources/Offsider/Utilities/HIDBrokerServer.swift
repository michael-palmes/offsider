import Darwin
import FBControlCore
import FBSimulatorControl
import Foundation
import OffsiderCore

/// How the broker reaches the simulator: one touch with no drain, as the connection stays open, or a whole event through idb's own pacing and drain.
struct HIDBrokerSink {
    var send: @MainActor (FBSimulatorHIDEvent) async throws -> Void
    var sendPaced: @MainActor (FBSimulatorHIDEvent) async throws -> Void

    @MainActor
    static func live(_ session: HIDInteractor.Session, logger: OffsiderLogger) -> HIDBrokerSink {
        HIDBrokerSink(
            send: { try await $0.sendAsync(on: session.hid) },
            sendPaced: { try await session.hid.send(event: $0, logger: logger) }
        )
    }
}

/// The sink plus the connection's clock and whether its command has gone.
struct HIDBrokerPlayer {
    var sink: HIDBrokerSink
    var sleep: @MainActor (Duration) async -> Void
    var peerGone: @MainActor () -> Bool
}

extension HIDBroker {
    static let delaySlice: Duration = .milliseconds(100)

    enum PlayOutcome: Equatable {
        case completed
        /// The command went part way through; what it may have left down is in the returned held input.
        case abandoned
    }

    /// Plays `event`, touches one at a time and keys or buttons whole, stopping when the command goes; returns what is left down, all it may have pressed if cut short.
    @MainActor
    static func play(
        _ event: FBSimulatorHIDEvent,
        keepHeld: Bool = false,
        held: HIDHeldInput,
        with player: HIDBrokerPlayer
    ) async -> (outcome: Result<PlayOutcome, Error>, held: HIDHeldInput) {
        if HIDBrokerEvent.isPaced(event) {
            return await playWhole(event, keepHeld: keepHeld, held: held, with: player)
        }
        var tracked = held
        do {
            for step in HIDBrokerEvent.steps(event) {
                if player.peerGone() { return (.success(.abandoned), tracked) }
                if case let .delay(seconds) = step {
                    var remaining = Duration.seconds(seconds)
                    while remaining > .zero {
                        if player.peerGone() { return (.success(.abandoned), tracked) }
                        let slice = min(remaining, delaySlice)
                        await player.sleep(slice)
                        remaining -= slice
                    }
                    continue
                }
                tracked.include(step)
                try await player.sink.send(step)
                tracked.apply(step)
            }
        } catch {
            return (.failure(error), tracked)
        }
        return (.success(.completed), keepHeld ? held : tracked)
    }

    @MainActor
    private static func playWhole(
        _ event: FBSimulatorHIDEvent,
        keepHeld: Bool,
        held: HIDHeldInput,
        with player: HIDBrokerPlayer
    ) async -> (outcome: Result<PlayOutcome, Error>, held: HIDHeldInput) {
        var possible = held
        possible.include(event)
        let sending = Task { @MainActor in try await player.sink.sendPaced(event) }
        let watcher = Task { @MainActor in
            while !Task.isCancelled {
                if player.peerGone() {
                    sending.cancel()
                    return
                }
                await player.sleep(delaySlice)
            }
        }
        defer { watcher.cancel() }
        do {
            try await sending.value
        } catch {
            return (sending.isCancelled ? .success(.abandoned) : .failure(error), possible)
        }
        var after = held
        after.apply(event)
        return (.success(.completed), keepHeld ? held : after)
    }
}

/// One request at a time on the simulator, in arrival order.
@MainActor
final class HIDBrokerTurn {
    private var busy = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func run<T>(_ body: () async -> T) async -> T {
        if busy {
            await withCheckedContinuation { waiting.append($0) }
        } else {
            busy = true
        }
        defer {
            if waiting.isEmpty { busy = false } else { waiting.removeFirst().resume() }
        }
        return await body()
    }
}

/// Reads newline-ended requests off one connection on a queue of its own: up to `silentWithin` for a request to start (forever when nil), then 2 s for the rest of it.
final class HIDBrokerFrameReader: @unchecked Sendable {
    enum Read: Equatable {
        case frame(Data)
        /// No request started within the wait.
        case silent
        /// The command closed, the broker shut the connection, or a request was too long or stalled.
        case closed
    }

    private let descriptor: Int32
    private let frameTimeoutMilliseconds: Int
    private let queue = DispatchQueue(label: "offsider.hid-broker.reader")
    private var buffer = Data()

    init(descriptor: Int32, frameTimeoutMilliseconds: Int = HIDBroker.serverIOTimeoutMilliseconds) {
        self.descriptor = descriptor
        self.frameTimeoutMilliseconds = frameTimeoutMilliseconds
    }

    func next(silentWithin milliseconds: Int32? = nil) async -> Read {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: self.readFrame(silentWithin: milliseconds)) }
        }
    }

    /// A frame begun must arrive whole within the frame time, however slowly its bytes trickle in.
    private func readFrame(silentWithin milliseconds: Int32?) -> Read {
        var chunk = [UInt8](repeating: 0, count: 16 * 1024)
        var deadline: UInt64?
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                let frame = Data(buffer[buffer.startIndex..<newline])
                buffer = Data(buffer[buffer.index(after: newline)...])
                return .frame(frame)
            }
            guard buffer.count < HIDBroker.maximumRequestBytes else { return .closed }
            let wait: Int32
            if buffer.isEmpty {
                wait = milliseconds ?? -1
            } else {
                let now = HIDBroker.monotonicTimeNanoseconds()
                let end = deadline ?? now + UInt64(max(1, frameTimeoutMilliseconds)) * 1_000_000
                deadline = end
                guard now < end else { return .closed }
                wait = Int32(clamping: max(1, (end - now) / 1_000_000))
            }
            var poller = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            let ready = poll(&poller, 1, wait)
            if ready < 0 {
                if errno == EINTR { continue }
                return .closed
            }
            guard ready > 0 else { return buffer.isEmpty ? .silent : .closed }
            let count = Darwin.read(descriptor, &chunk, chunk.count)
            if count < 0 {
                if errno == EINTR || errno == EAGAIN { continue }
                return .closed
            }
            guard count > 0 else { return .closed }
            buffer.append(contentsOf: chunk[..<count])
        }
    }
}

/// The broker's loop: admits this user's commands, serves each on its own connection, sends their input one request at a time, lifts what a command left down when it goes, and stops when idle.
@MainActor
final class HIDBrokerServer {
    static let maxConnections = 32
    static let acceptPollMilliseconds: Int32 = 200

    let udid: String
    private let listener: Int32
    private let endpoint: String?
    private let endpointIdentity: HIDBrokerSocketIdentity?
    private let sink: HIDBrokerSink
    private let isCurrentBoot: () -> Bool
    private let admits: (Int32) -> Bool
    private let writeLog: (String) -> Void
    private(set) var idleSeconds: Int
    private let maxLifetime: Duration
    private let startedAt = Date()
    private let startedClock = ContinuousClock.now
    private var lastUse = ContinuousClock.now
    private var connections: [Int32: Task<Void, Never>] = [:]
    /// Connections waiting for their command's next request, which a stop can close without cutting off any input.
    private var waiting: Set<Int32> = []
    private var stopReason: String?
    /// Whether the stop cuts off input still being sent, as `session stop` and a signal do; a failed input lets it finish.
    private var cutsOff = false
    private let turn = HIDBrokerTurn()

    /// `endpoint` is unlinked on the way out, unless another broker has since bound it.
    init(
        udid: String,
        listener: Int32,
        endpoint: String?,
        sink: HIDBrokerSink,
        isCurrentBoot: @escaping () -> Bool,
        admits: @escaping (Int32) -> Bool,
        idleSeconds: Int,
        maxLifetime: Duration = .seconds(SimulatorSessionSettings.maxLifetimeSeconds),
        log: @escaping (String) -> Void
    ) {
        self.udid = udid
        self.listener = listener
        self.endpoint = endpoint
        self.endpointIdentity = endpoint.flatMap { try? HIDBroker.socketIdentity(at: $0) }
        self.sink = sink
        self.isCurrentBoot = isCurrentBoot
        self.admits = admits
        self.idleSeconds = idleSeconds
        self.maxLifetime = maxLifetime
        self.writeLog = log
        // Non-blocking, so a client that leaves between the poll and the accept cannot stall the loop.
        _ = fcntl(listener, F_SETFL, fcntl(listener, F_GETFL) | O_NONBLOCK)
    }

    func log(_ line: String) {
        writeLog(line)
    }

    /// Stops within one accept poll, lifting what each attached command left down; without `cutOff`, input already under way finishes first.
    func requestStop(_ reason: String, cutOff: Bool = true) {
        stopReason = stopReason ?? reason
        cutsOff = cutsOff || cutOff
    }

    /// Serves until idle, asked to stop, the simulator restarts or input fails; returns why it stopped.
    func run() async -> String {
        while stopReason == nil {
            if let client = await Self.accept(on: listener, waitingMs: Self.acceptPollMilliseconds) {
                admit(client)
            }
            guard connections.isEmpty else { continue }
            if ContinuousClock.now - lastUse >= .seconds(idleSeconds) {
                stopReason = "idle for \(idleSeconds) s"
            } else if ContinuousClock.now - startedClock >= maxLifetime {
                stopReason = "12 hours old"
            }
        }
        Darwin.close(listener)
        if let endpoint { try? HIDBroker.removeOwnedSocket(endpoint, matching: endpointIdentity) }
        let open = Array(connections)
        // A closed connection's next request fails as not sent, so its command opens its own session.
        for (descriptor, _) in open where cutsOff || waiting.contains(descriptor) { Darwin.shutdown(descriptor, SHUT_RDWR) }
        for (_, task) in open { await task.value }
        return stopReason ?? "stopped"
    }

    var status: HIDBrokerStatus {
        HIDBrokerStatus(
            udid: udid,
            pid: getpid(),
            startedAt: startedAt.timeIntervalSince1970,
            idleSeconds: idleSeconds,
            idleFor: Int((ContinuousClock.now - lastUse).components.seconds),
            attached: max(0, connections.count - 1),
            state: stopReason == nil ? "ready" : "stopping"
        )
    }

    nonisolated private static func accept(on listener: Int32, waitingMs: Int32) async -> Int32? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var poller = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
                guard poll(&poller, 1, waitingMs) > 0 else {
                    continuation.resume(returning: nil)
                    return
                }
                let client = CloseOnExecSocket.accept(listener)
                continuation.resume(returning: client >= 0 ? client : nil)
            }
        }
    }

    private func admit(_ client: Int32) {
        // Another user's client, or another build's, gets no bytes at all, not even the handshake; a full broker closes before checking.
        guard connections.count < Self.maxConnections, HIDBroker.isSameUserPeer(client), admits(client) else {
            Darwin.close(client)
            return
        }
        _ = fcntl(client, F_SETFL, fcntl(client, F_GETFL) & ~O_NONBLOCK)
        HIDBroker.configureNoSignalPipe(client)
        guard (try? HIDBroker.configureSocketTimeouts(client, readMilliseconds: HIDBroker.serverIOTimeoutMilliseconds, writeMilliseconds: HIDBroker.serverIOTimeoutMilliseconds)) != nil else {
            Darwin.close(client)
            return
        }
        guard isCurrentBoot() else {
            try? HIDBroker.writeHandshake(ready: false, to: client)
            Darwin.close(client)
            stopReason = "the simulator restarted"
            return
        }
        guard (try? HIDBroker.writeHandshake(ready: true, to: client)) != nil else {
            Darwin.close(client)
            return
        }
        connections[client] = Task { await self.serve(client) }
    }

    private func serve(_ client: Int32) async {
        let reader = HIDBrokerFrameReader(descriptor: client)
        var held = HIDHeldInput()
        // A command counts as use when it goes; `session status` and `stop` do not.
        var isCommand = true
        requests: while true {
            waiting.insert(client)
            // A command silent for the idle time, holding nothing down, is closed; its next input opens a session of its own.
            let read = await reader.next(silentWithin: held.isEmpty ? Int32(clamping: idleSeconds * 1000) : nil)
            waiting.remove(client)
            guard case .frame(let frame) = read, stopReason == nil || !cutsOff else {
                if read == .silent { log("Closed a command silent for \(idleSeconds) s") }
                break
            }
            guard let request = try? JSONDecoder().decode(HIDBrokerRequest.self, from: frame) else {
                reply(HIDBrokerReply(error: "The simulator input broker could not read a request. Nothing was sent."), to: client)
                break
            }
            switch request.op {
            case .status:
                isCommand = false
                reply(HIDBrokerReply(status: status), to: client)
            case .stop:
                isCommand = false
                requestStop("asked to stop")
                reply(HIDBrokerReply(), to: client)
            case .input:
                guard let event = request.event?.hid else {
                    reply(HIDBrokerReply(error: "The simulator input broker got a request with no input. Nothing was sent."), to: client)
                    continue
                }
                guard stopReason == nil else {
                    reply(HIDBrokerReply(error: "The simulator's input session is stopping. Nothing was sent; run the command again.", notSent: true), to: client)
                    continue
                }
                do {
                    try HIDBrokerEvent.validate(event)
                } catch {
                    reply(HIDBrokerReply(error: HIDBroker.brokerResponseDescription(for: error)), to: client)
                    continue
                }
                if let seconds = request.idleSeconds {
                    idleSeconds = min(max(seconds, 1), SimulatorSessionSettings.maxIdleSeconds)
                }
                let stabilization = min(request.stabilizationMs ?? HIDStabilization.defaultMilliseconds, HIDStabilization.maximumMilliseconds)
                let player = HIDBrokerPlayer(
                    sink: sink,
                    sleep: { try? await Task.sleep(for: $0) },
                    peerGone: { SocketPeer.closed(client) }
                )
                let outcome: Result<HIDBroker.PlayOutcome, Error> = await turn.run {
                    let played = await HIDBroker.play(event, keepHeld: request.keepHeld == true, held: held, with: player)
                    held = played.held
                    switch played.outcome {
                    case .success(.completed):
                        if stabilization > 0 { try? await Task.sleep(for: .milliseconds(stabilization)) }
                    case .success(.abandoned), .failure:
                        held = await lift(held)
                    }
                    return played.outcome
                }
                lastUse = .now
                isCommand = true
                switch outcome {
                case .success(.completed):
                    reply(HIDBrokerReply(), to: client)
                    if stopReason != nil { break requests }
                case .success(.abandoned):
                    log("A command went part way through its input; lifted what it left down")
                    break requests
                case .failure(let error):
                    log("Input failed: \(error.localizedDescription)")
                    requestStop("input failed", cutOff: false)
                    reply(HIDBrokerReply(error: HIDBroker.brokerResponseDescription(for: error)), to: client)
                    break requests
                }
            }
        }
        if !held.isEmpty {
            let left = held
            _ = await turn.run { await lift(left) }
        }
        Darwin.close(client)
        connections.removeValue(forKey: client)
        if isCommand { lastUse = .now }
    }

    /// Lifts everything in `held`, best effort; returns nothing held.
    private func lift(_ held: HIDHeldInput) async -> HIDHeldInput {
        if let release = held.release {
            do {
                try await sink.sendPaced(release)
            } catch {
                log("Could not lift input a command left down: \(error.localizedDescription)")
            }
        }
        return HIDHeldInput()
    }

    private func reply(_ reply: HIDBrokerReply, to client: Int32) {
        try? HIDBroker.writeReply(reply, to: client)
    }
}
