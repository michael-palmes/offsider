import Darwin
import FBSimulatorControl
import Foundation
import OffsiderCore
import Testing
@testable import Offsider

/// What the fake simulator received: each event the broker sent, and whether it went whole through idb's pacing.
@MainActor
private final class FakeSimulator {
    var sent: [(event: FBSimulatorHIDEvent, paced: Bool)] = []
    var slept: [Duration] = []
    var failOn: FBSimulatorHIDEvent?
    /// A paced send waits this long, so a test can cut its command off mid-way.
    var pacedHold: Duration = .zero

    var sink: HIDBrokerSink {
        HIDBrokerSink(
            send: { event in
                if event == self.failOn { throw CLIError(errorDescription: "The simulator stopped answering.", reason: .hidBrokerFailed) }
                self.sent.append((event, false))
            },
            sendPaced: { event in
                self.sent.append((event, true))
                if self.pacedHold > .zero { try await Task.sleep(for: self.pacedHold) }
            }
        )
    }

    func player(peerGone: @escaping @MainActor () -> Bool = { false }) -> HIDBrokerPlayer {
        HIDBrokerPlayer(sink: sink, sleep: { self.slept.append($0); await Task.yield() }, peerGone: peerGone)
    }

    var events: [FBSimulatorHIDEvent] { sent.map(\.event) }
}

@MainActor
private final class Flag {
    var value = false
}

@Suite("HID broker held input")
struct HIDHeldInputTests {
    @Test("A tap, a swipe or a key press leaves nothing down; a lone down leaves exactly that")
    func applyTracksWhatStaysDown() {
        var held = HIDHeldInput()
        held.apply(.tapAt(x: 1, y: 2))
        held.apply(.swipe(1, yStart: 2, xEnd: 3, yEnd: 40, delta: 10, duration: 0.2))
        held.apply(.shortKeyPress(4))
        held.apply(.shortButtonPress(.homeButton))
        #expect(held.isEmpty)

        held.apply(.touch(direction: .down, x: 5, y: 6))
        held.apply(.touch(direction: .down, x: 7, y: 8))
        held.apply(.keyboard(direction: .down, keyCode: 225))
        held.apply(.button(direction: .down, button: .lock))
        #expect(held.touch == HIDHeldInput.Point(x: 7, y: 8))
        #expect(held.keys == [225] && held.buttons == [FBSimulatorHIDButton.lock.rawValue])
    }

    @Test("An event cut off part way counts everything it presses as down, ups or not")
    func includeIsConservative() {
        var held = HIDHeldInput()
        held.include(.composite([.shortKeyPress(4), .twoFingerTouch(direction: .down, finger1: CGPoint(x: 1, y: 1), finger2: CGPoint(x: 2, y: 2))]))
        #expect(held.keys == [4])
        #expect(held.fingers == [HIDHeldInput.Point(x: 1, y: 1), HIDHeldInput.Point(x: 2, y: 2)])
    }

    @Test("The release lifts keys, then buttons, then fingers, at the points they went down; Apple Pay is never held")
    func releaseOrder() {
        var held = HIDHeldInput()
        held.apply(.button(direction: .down, button: .applePay))
        #expect(held.release == nil)
        held.apply(.composite([
            .touch(direction: .down, x: 3, y: 4),
            .button(direction: .down, button: .siri),
            .keyboard(direction: .down, keyCode: 9),
        ]))
        #expect(held.release == .composite([
            .keyboard(direction: .up, keyCode: 9),
            .button(direction: .up, button: .siri),
            .touch(direction: .up, x: 3, y: 4),
        ]))
    }
}

@Suite("HID broker play")
@MainActor
struct HIDBrokerPlayTests {
    @Test("Touches go one at a time with no drain; pauses sleep in 100 ms slices")
    func touchesAreSentStepByStep() async throws {
        let simulator = FakeSimulator()
        let played = await HIDBroker.play(
            .composite([.touch(direction: .down, x: 1, y: 1), .delay(0.25), .touch(direction: .up, x: 1, y: 1)]),
            held: HIDHeldInput(),
            with: simulator.player()
        )
        #expect(try played.outcome.get() == .completed)
        #expect(played.held.isEmpty)
        #expect(simulator.sent.map(\.paced) == [false, false])
        #expect(simulator.slept == [.milliseconds(100), .milliseconds(100), .milliseconds(50)])
    }

    @Test("A command that goes mid-pause ends its request within a slice, with its touch still to lift")
    func abandonedPause() async throws {
        let simulator = FakeSimulator()
        var checks = 0
        let played = await HIDBroker.play(
            .composite([.touch(direction: .down, x: 5, y: 6), .delay(10), .touch(direction: .up, x: 5, y: 6)]),
            held: HIDHeldInput(),
            with: simulator.player(peerGone: {
                checks += 1
                return checks > 3
            })
        )
        #expect(try played.outcome.get() == .abandoned)
        #expect(played.held.touch == HIDHeldInput.Point(x: 5, y: 6))
        #expect(simulator.events == [.touch(direction: .down, x: 5, y: 6)])
        #expect(simulator.slept.count <= 3)
    }

    @Test("A touch that fails after a contact went down still reports that contact to lift")
    func failedTouchKeepsTheContact() async {
        let simulator = FakeSimulator()
        simulator.failOn = .touch(direction: .down, x: 2, y: 2)
        let played = await HIDBroker.play(
            .composite([.touch(direction: .down, x: 1, y: 1), .touch(direction: .down, x: 2, y: 2)]),
            held: HIDHeldInput(),
            with: simulator.player()
        )
        #expect(throws: CLIError.self) { try played.outcome.get() }
        #expect(played.held.touch != nil)
    }

    @Test("A detached touch stays down once its request completes, and is lifted only when its command goes part way")
    func keepHeld() async throws {
        let simulator = FakeSimulator()
        let completed = await HIDBroker.play(.touch(direction: .down, x: 1, y: 1), keepHeld: true, held: HIDHeldInput(), with: simulator.player())
        #expect(try completed.outcome.get() == .completed)
        #expect(completed.held.isEmpty)

        let cut = await HIDBroker.play(
            .composite([.touch(direction: .down, x: 1, y: 1), .delay(5)]), keepHeld: true, held: HIDHeldInput(),
            with: simulator.player(peerGone: { simulator.sent.count > 1 })
        )
        #expect(try cut.outcome.get() == .abandoned)
        #expect(cut.held.touch != nil)
    }

    @Test("Keys and buttons go whole through idb's pacing, and the result is what they leave down")
    func pacedEventsGoWhole() async throws {
        let simulator = FakeSimulator()
        let event = FBSimulatorHIDEvent.composite([.shortKeyPress(4), .keyboard(direction: .down, keyCode: 225)])
        let played = await HIDBroker.play(event, held: HIDHeldInput(), with: simulator.player())
        #expect(try played.outcome.get() == .completed)
        #expect(simulator.sent.count == 1 && simulator.sent[0].paced && simulator.sent[0].event == event)
        #expect(played.held.keys == [225])
    }

    @Test("Paced input stops when its command goes, and everything it presses counts as down")
    func pacedInputIsCancelled() async throws {
        let simulator = FakeSimulator()
        simulator.pacedHold = .seconds(600)
        let gone = Flag()
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(50))
            gone.value = true
        }
        let start = ContinuousClock.now
        let played = await HIDBroker.play(
            .composite([.shortKeyPress(4), .shortButtonPress(.siri)]),
            held: HIDHeldInput(),
            with: HIDBrokerPlayer(sink: simulator.sink, sleep: { _ in try? await Task.sleep(for: .milliseconds(10)) }, peerGone: { gone.value })
        )
        #expect(try played.outcome.get() == .abandoned)
        #expect(ContinuousClock.now - start < .seconds(60))
        #expect(played.held.keys == [4] && played.held.buttons == [FBSimulatorHIDButton.siri.rawValue])
    }
}

@Suite("HID broker server", .serialized)
@MainActor
struct HIDBrokerServerTests {
    private struct Running {
        let server: HIDBrokerServer
        let task: Task<String, Never>
        let endpoint: String
        let simulator: FakeSimulator
    }

    private func start(idleSeconds: Int = 60, isCurrentBoot: @escaping () -> Bool = { true }) throws -> Running {
        let endpoint = FileManager.default.temporaryDirectory.appendingPathComponent("hb-\(UUID().uuidString.prefix(8)).sock").path
        let listener = try HIDBroker.makeListener(at: endpoint)
        let simulator = FakeSimulator()
        let server = HIDBrokerServer(
            udid: "SIM-A", listener: listener, endpoint: endpoint, sink: simulator.sink,
            isCurrentBoot: isCurrentBoot, admits: { _ in true }, idleSeconds: idleSeconds, log: { _ in }
        )
        return Running(server: server, task: Task { await server.run() }, endpoint: endpoint, simulator: simulator)
    }

    private func stop(_ running: Running) async -> String {
        running.server.requestStop("test over")
        return await running.task.value
    }

    nonisolated private static func open(_ endpoint: String) throws -> Int32 {
        // A busy test host can hold the main actor for seconds.
        try HIDBroker.connectAndAwaitHandshake(endpoint: endpoint, connector: HIDBroker.connect(to:), timeoutMilliseconds: 15_000)
    }

    nonisolated private static func send(_ event: FBSimulatorHIDEvent, keepHeld: Bool = false, idleSeconds: Int = 60, on descriptor: Int32) throws {
        let environment = [HIDStabilization.environmentKey: "0", SimulatorSessionSettings.idleVariable: "\(idleSeconds)"]
        let request = try HIDBroker.request(for: event, keepHeld: keepHeld, environment: environment)
        try HIDBroker.exchange(request.data, on: descriptor, timeoutMilliseconds: request.timeoutMilliseconds)
    }

    nonisolated private static func offMain<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async { continuation.resume(with: Result { try body() }) }
        }
    }

    private func waitUntil(_ condition: () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(20)) }
    }

    @Test("A command's requests share one connection, and a touch it leaves down is lifted when it goes")
    func liftsWhatACommandLeavesDown() async throws {
        let running = try start()
        let endpoint = running.endpoint
        try await Self.offMain {
            let descriptor = try Self.open(endpoint)
            try Self.send(.tapAt(x: 1, y: 2), on: descriptor)
            try Self.send(.touch(direction: .down, x: 3, y: 4), on: descriptor)
            Darwin.close(descriptor)
        }
        await waitUntil { running.simulator.sent.count == 4 }
        #expect(running.simulator.events == [
            .touch(direction: .down, x: 1, y: 2), .touch(direction: .up, x: 1, y: 2), .touch(direction: .down, x: 3, y: 4),
            .composite([.touch(direction: .up, x: 3, y: 4)]),
        ])
        #expect(await stop(running) == "test over")
        #expect(!FileManager.default.fileExists(atPath: endpoint))
    }

    @Test("A touch a command lifts itself is not lifted again, and a detached touch stays down after its command")
    func noSpareLifts() async throws {
        let running = try start()
        let endpoint = running.endpoint
        try await Self.offMain {
            let descriptor = try Self.open(endpoint)
            try Self.send(.touch(direction: .down, x: 1, y: 1), on: descriptor)
            try Self.send(.touch(direction: .up, x: 1, y: 1), on: descriptor)
            Darwin.close(descriptor)
            let detached = try Self.open(endpoint)
            try Self.send(.touch(direction: .down, x: 9, y: 9), keepHeld: true, on: detached)
            Darwin.close(detached)
        }
        _ = await stop(running)
        #expect(running.simulator.events == [.touch(direction: .down, x: 1, y: 1), .touch(direction: .up, x: 1, y: 1), .touch(direction: .down, x: 9, y: 9)])
    }

    @Test("Status names the simulator and other attached commands, and reading it is not use")
    func statusIsNotUse() async throws {
        let running = try start()
        let endpoint = running.endpoint
        let held = try await Self.offMain { try Self.open(endpoint) }
        defer { Darwin.close(held) }
        try await Task.sleep(for: .milliseconds(1100))
        let first = try #require(await Self.offMain { HIDBroker.control(.status, at: endpoint)?.status })
        let second = try #require(await Self.offMain { HIDBroker.control(.status, at: endpoint)?.status })
        #expect(first.udid == "SIM-A" && first.pid == getpid() && first.attached == 1)
        #expect(second.idleFor >= 1)
        _ = await stop(running)
    }

    @Test("A stop request ends the broker and removes its socket")
    func stopRequest() async throws {
        let running = try start()
        let endpoint = running.endpoint
        let reply = await Self.offMainReply { HIDBroker.control(.stop, at: endpoint) }
        #expect(reply == HIDBrokerReply())
        #expect(await running.task.value == "asked to stop")
        #expect(!FileManager.default.fileExists(atPath: endpoint))
    }

    @Test("The broker stops once idle with no command attached, never while one holds input down")
    func idlesOutOnlyWhenFree() async throws {
        let running = try start(idleSeconds: 1)
        let endpoint = running.endpoint
        let descriptor = try await Self.offMain {
            let descriptor = try Self.open(endpoint)
            try Self.send(.touch(direction: .down, x: 1, y: 1), idleSeconds: 1, on: descriptor)
            return descriptor
        }
        try await Task.sleep(for: .milliseconds(2500))
        #expect(FileManager.default.fileExists(atPath: endpoint))
        Darwin.close(descriptor)
        let start = ContinuousClock.now
        #expect(await running.task.value == "idle for 1 s")
        #expect(ContinuousClock.now - start >= .milliseconds(800))
    }

    @Test("A command silent for the idle time, holding nothing down, is closed so the broker can idle out, and its next input goes its own way")
    func silentCommandIsClosed() async throws {
        let running = try start(idleSeconds: 1)
        let endpoint = running.endpoint
        let descriptor = try await Self.offMain { try Self.open(endpoint) }
        defer { Darwin.close(descriptor) }
        await waitUntil { !FileManager.default.fileExists(atPath: endpoint) }
        #expect(!FileManager.default.fileExists(atPath: endpoint))
        let error = await Self.offMainError { try Self.send(.tapAt(x: 1, y: 1), on: descriptor) }
        #expect(error is HIDBrokerNotSent)
        #expect(running.simulator.sent.isEmpty)
    }

    @Test("Input that fails stops the broker without cutting off another command's input already queued, which finishes and is answered")
    func failureLetsQueuedInputFinish() async throws {
        let running = try start()
        running.simulator.failOn = .touch(direction: .down, x: 7, y: 7)
        let endpoint = running.endpoint
        async let failed = Self.offMainError {
            let descriptor = try Self.open(endpoint)
            defer { Darwin.close(descriptor) }
            try Self.send(.composite([.delay(0.6), .touch(direction: .down, x: 7, y: 7)]), on: descriptor)
        }
        try await Task.sleep(for: .milliseconds(200))
        async let queued = Self.offMainError {
            let descriptor = try Self.open(endpoint)
            defer { Darwin.close(descriptor) }
            try Self.send(.tapAt(x: 2, y: 2), on: descriptor)
        }
        let (first, second) = await (failed, queued)
        #expect(first is CLIError)
        #expect(second == nil, "\(String(describing: second))")
        #expect(await running.task.value == "input failed")
    }

    @Test("Status reads stopping once a stop is asked for")
    func statusSaysStopping() async throws {
        let running = try start()
        #expect(running.server.status.state == "ready")
        running.server.requestStop("test over")
        #expect(running.server.status.state == "stopping")
        _ = await running.task.value
    }

    @Test("A command reaching a broker whose simulator restarted is told it is not ready, and the broker stops")
    func restartedSimulator() async throws {
        let running = try start(isCurrentBoot: { false })
        let endpoint = running.endpoint
        let error = await Self.offMainError { _ = try Self.open(endpoint) }
        #expect(error is HIDBrokerNotReadyError)
        #expect(await running.task.value == "the simulator restarted")
    }

    @Test("A request the broker cannot read gets an error and sends nothing")
    func unreadableRequest() async throws {
        let running = try start()
        let endpoint = running.endpoint
        let error = await Self.offMainError {
            let descriptor = try Self.open(endpoint)
            defer { Darwin.close(descriptor) }
            try HIDBroker.exchange(Data(#"{"op":"input","event":["t",true]}"#.utf8 + [0x0A]), on: descriptor)
        }
        #expect((error as? CLIError)?.reason == .hidBrokerFailed)
        #expect(running.simulator.sent.isEmpty)
        _ = await stop(running)
    }

    @Test("Input that fails stops the broker after lifting what was down and telling the command")
    func failedInputStopsTheBroker() async throws {
        let running = try start()
        running.simulator.failOn = .touch(direction: .up, x: 1, y: 1)
        let endpoint = running.endpoint
        let error = await Self.offMainError {
            let descriptor = try Self.open(endpoint)
            defer { Darwin.close(descriptor) }
            try Self.send(.tapAt(x: 1, y: 1), on: descriptor)
        }
        #expect((error as? CLIError)?.userFacingDescription.contains("stopped answering") == true)
        #expect(await running.task.value == "input failed")
        #expect(running.simulator.events.last == .composite([.touch(direction: .up, x: 1, y: 1)]))
    }

    nonisolated private static func offMainReply(_ body: @escaping @Sendable () -> HIDBrokerReply?) async -> HIDBrokerReply? {
        await HIDBroker.offMain(body)
    }

    nonisolated private static func offMainError(_ body: @escaping @Sendable () throws -> Void) async -> Error? {
        await HIDBroker.offMain {
            do {
                try body()
                return nil
            } catch {
                return error
            }
        }
    }
}

@Suite("HID broker attach")
struct HIDBrokerAttachTests {
    private func endpoint() throws -> String {
        try HIDBroker.endpointPath(simulatorUDID: UUID().uuidString, developerDirectory: FileManager.default.temporaryDirectory.path)
    }

    @Test("A command finds no broker as absent, so it starts one; a starting one as unavailable, so it does not")
    func attachOutcomes() throws {
        let endpoint = try endpoint()
        defer { try? FileManager.default.removeItem(atPath: endpoint + ".lifetime.lock") }
        let refused: (String) throws -> Int32 = { _ in throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT)) }
        #expect(HIDBroker.attach(endpoint: endpoint, connector: refused) == .absent)

        let lifetime = try HIDBroker.acquireLifetimeLock(endpoint: endpoint)
        defer { Darwin.close(lifetime) }
        #expect(HIDBroker.attach(endpoint: endpoint, connector: refused) == .unavailable)
    }

    @Test("A ready broker's handshake hands the command its connection; a stale one is replaced after the command, a garbled one left alone")
    func attachReady() throws {
        var pair: [Int32] = [0, 0]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0)
        defer { Darwin.close(pair[1]) }
        try HIDBroker.writeHandshake(ready: true, to: pair[1])
        guard case .ready(let descriptor) = HIDBroker.attach(endpoint: "unused", connector: { _ in pair[0] }) else {
            Issue.record("A ready handshake should attach")
            return
        }
        Darwin.close(descriptor)

        var stale: [Int32] = [0, 0]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &stale) == 0)
        defer { Darwin.close(stale[1]) }
        try HIDBroker.writeHandshake(ready: false, to: stale[1])
        #expect(HIDBroker.attach(endpoint: "unused", connector: { _ in stale[0] }) == .absent)

        var silent: [Int32] = [0, 0]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &silent) == 0)
        defer { Darwin.close(silent[1]) }
        try HIDBroker.writeAll(Data("{}\n".utf8), to: silent[1])
        #expect(HIDBroker.attach(endpoint: "unused", connector: { _ in silent[0] }) == .unavailable)
    }

    @Test("A request the broker never took or refused while stopping is not sent; a reply that does not come back leaves the outcome unknown")
    func notSentAgainstUnknown() throws {
        var closed: [Int32] = [0, 0]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &closed) == 0)
        HIDBroker.configureNoSignalPipe(closed[0])
        Darwin.close(closed[1])
        defer { Darwin.close(closed[0]) }
        #expect(throws: HIDBrokerNotSent.self) { try HIDBroker.exchange(Data("{}\n".utf8), on: closed[0]) }

        var silent: [Int32] = [0, 0]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &silent) == 0)
        defer { silent.forEach { Darwin.close($0) } }
        let error = #expect(throws: CLIError.self) { try HIDBroker.exchange(Data("{}\n".utf8), on: silent[0], timeoutMilliseconds: 100) }
        #expect(error?.reason == .inputOutcomeUnknown)

        var stopping: [Int32] = [0, 0]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &stopping) == 0)
        defer { stopping.forEach { Darwin.close($0) } }
        try HIDBroker.writeReply(HIDBrokerReply(error: "stopping", notSent: true), to: stopping[1])
        #expect(throws: HIDBrokerNotSent.self) { try HIDBroker.exchange(Data("{}\n".utf8), on: stopping[0], timeoutMilliseconds: 1000) }
    }

    @Test("A broker that exits before it listens ends the wait at once instead of after 30 s")
    func spawnedBrokerExit() throws {
        let endpoint = try endpoint()
        defer { ["lock", "lifetime.lock"].forEach { try? FileManager.default.removeItem(atPath: endpoint + "." + $0) } }
        var spawned = 0
        var now: UInt64 = 0
        let error = #expect(throws: HIDBrokerNotReadyError.self) {
            _ = try HIDBroker.connectToReadyBroker(
                simulatorUDID: "simulator-a",
                endpoint: endpoint,
                connector: { _ in throw NSError(domain: NSPOSIXErrorDomain, code: Int(ECONNREFUSED)) },
                spawner: { _ in spawned += 1 },
                sleeper: { _ in now += 100_000_000 },
                monotonicNow: { now },
                spawnedBrokerExited: { spawned > 0 }
            )
        }
        #expect(error?.diagnosticDescription.contains("exited before it listened") == true)
        #expect(spawned == 1)
        #expect(now < 1_000_000_000)
    }

    @Test("Only live brokers of this protocol are listed, starting ones included")
    func liveEndpoints() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("hb-\(UUID().uuidString.prefix(8))").path
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        let version = BrokerEndpointNaming.protocolVersion
        let live = (root as NSString).appendingPathComponent("a-b-v\(version).sock")
        let stale = (root as NSString).appendingPathComponent("c-d-v\(version).sock")
        let older = (root as NSString).appendingPathComponent("e-f-v\(version - 1).sock")
        let liveLock = try HIDBroker.acquireLifetimeLock(endpoint: live)
        let olderLock = try HIDBroker.acquireLifetimeLock(endpoint: older)
        defer { [liveLock, olderLock].forEach { Darwin.close($0) } }
        Darwin.close(try HIDBroker.acquireLifetimeLock(endpoint: stale))
        #expect(HIDBroker.liveEndpoints(root: root) == [live])
    }

    @Test("Stopping one simulator's session looks only at that simulator's broker, whatever case its UDID was typed in")
    func liveEndpointsForOneSimulator() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("hb-\(UUID().uuidString.prefix(8))").path
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        let version = BrokerEndpointNaming.protocolVersion
        func endpoint(_ udid: String) -> String {
            (root as NSString).appendingPathComponent(String(BrokerEndpointNaming.fnv1a64(udid), radix: 36) + "-x-v\(version).sock")
        }
        let mine = endpoint("SIM-A")
        let other = endpoint("SIM-B")
        let locks = try [mine, other].map { try HIDBroker.acquireLifetimeLock(endpoint: $0) }
        defer { locks.forEach { Darwin.close($0) } }
        #expect(HIDBroker.liveEndpoints(root: root, simulatorUDID: "sim-a") == [mine])
        #expect(HIDBroker.liveEndpoints(root: root, simulatorUDID: "emulator-5554").isEmpty)
    }

    @Test("Closing a connection returns at once even while a reply is still awaited, and the waiting send ends as not sent or unknown")
    func closeDoesNotWaitForAReply() async throws {
        var pair: [Int32] = [0, 0]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0)
        defer { Darwin.close(pair[1]) }
        let connection = HIDBrokerConnection(descriptor: pair[0])
        let send = Task { try await connection.send(.tapAt(x: 1, y: 1), environment: [:]) }
        try await Task.sleep(for: .milliseconds(200))
        let start = ContinuousClock.now
        connection.close()
        #expect(ContinuousClock.now - start < .seconds(1))
        let result = await send.result
        #expect(throws: (any Error).self) { try result.get() }
        #expect(ContinuousClock.now - start < .seconds(5))
    }
}

@Suite("Simulator session settings")
struct SimulatorSessionSettingsTests {
    @Test("The warm session is on unless set off; anything else is refused with the values to use")
    func mode() throws {
        #expect(try SimulatorSessionSettings.isWarm([:]))
        #expect(try SimulatorSessionSettings.isWarm(["OFFSIDER_SIMULATOR_SESSION": " On "]))
        #expect(try !SimulatorSessionSettings.isWarm(["OFFSIDER_SIMULATOR_SESSION": "off"]))
        let error = #expect(throws: CLIError.self) { try IOSBackend.keepsInputWarm(["OFFSIDER_SIMULATOR_SESSION": "auto"]) }
        #expect(error?.reason == .usage)
        #expect(error?.userFacingDescription.contains("use on or off") == true)
    }

    @Test("Idle is 60 s unless set to a positive whole number, at most 3600")
    func idle() {
        #expect(SimulatorSessionSettings.idleSeconds([:]) == 60)
        #expect(SimulatorSessionSettings.idleSeconds(["OFFSIDER_SIMULATOR_SESSION_IDLE": "5"]) == 5)
        #expect(SimulatorSessionSettings.idleSeconds(["OFFSIDER_SIMULATOR_SESSION_IDLE": "0"]) == 60)
        #expect(SimulatorSessionSettings.idleSeconds(["OFFSIDER_SIMULATOR_SESSION_IDLE": "soon"]) == 60)
        #expect(SimulatorSessionSettings.idleSeconds(["OFFSIDER_SIMULATOR_SESSION_IDLE": "99999"]) == 3600)
    }
}

@Suite("HID broker frame reader")
struct HIDBrokerFrameReaderTests {
    @Test("a request that trickles in one byte at a time is closed once the frame time passes, not stretched by each byte")
    func trickledFrameIsClosedAtTheDeadline() async throws {
        var pair: [Int32] = [0, 0]
        try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0)
        defer { pair.forEach { Darwin.close($0) } }
        let reader = HIDBrokerFrameReader(descriptor: pair[0], frameTimeoutMilliseconds: 200)
        let firstByteAt = Clock()
        let dripping = Task.detached {
            for index in 0..<40 {
                var byte: UInt8 = 0x7B
                if index == 0 { firstByteAt.mark() }
                _ = Darwin.write(pair[1], &byte, 1)
                try? await Task.sleep(for: .milliseconds(30))
            }
        }
        let read = await reader.next(silentWithin: 5_000)
        let closedAt = ContinuousClock.now
        dripping.cancel()
        #expect(read == .closed)
        // Measured from the first byte, so a late start of the writer under a busy test run does not count.
        let held = closedAt - (firstByteAt.marked ?? closedAt)
        #expect(held >= .milliseconds(150) && held < .milliseconds(900), "\(held)")
    }

    final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var at: ContinuousClock.Instant?
        func mark() { lock.withLock { if at == nil { at = .now } } }
        var marked: ContinuousClock.Instant? { lock.withLock { at } }
    }

    @Test("a whole frame that arrives in pieces within the frame time is returned")
    func pieceMealFrameIsReturned() async throws {
        var pair: [Int32] = [0, 0]
        try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0)
        defer { pair.forEach { Darwin.close($0) } }
        let reader = HIDBrokerFrameReader(descriptor: pair[0], frameTimeoutMilliseconds: 2_000)
        Task {
            for piece in ["{\"op\":", "\"status\"", "}\n"] {
                _ = piece.utf8CString.withUnsafeBufferPointer { Darwin.write(pair[1], $0.baseAddress, piece.utf8.count) }
                try? await Task.sleep(for: .milliseconds(20))
            }
        }
        let read = await reader.next(silentWithin: 5_000)
        #expect(read == .frame(Data("{\"op\":\"status\"}".utf8)))
    }
}
