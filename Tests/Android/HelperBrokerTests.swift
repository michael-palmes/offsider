import Foundation
import Testing
import OffsiderCore
@testable import OffsiderAndroid

/// A broker on a real Unix socket in a fresh private folder, serving a helper on the fake device.
@MainActor
final class BrokerFixture {
    let device: FakeHelperDevice
    let root: URL
    let directory: String
    let broker: HelperBroker
    private(set) var running: Task<Void, any Error>?
    private(set) var spawns = 0

    let idle: Duration

    init(
        device: FakeHelperDevice = FakeHelperDevice(), idle: Duration = .seconds(30), dexSha256: String = FakeHelperDevice.dex.sha256, maxClients: Int = 8,
        startDelay: Duration = .zero, pingTimeout: Duration = HelperSession.requestTimeout
    ) {
        self.idle = idle
        self.device = device
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ob-\(UUID().uuidString.prefix(8))")
        directory = root.appendingPathComponent("s").path
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let socket = HelperBrokerPaths(serial: FakeHelperDevice.serial, directory: directory).socket
        broker = HelperBroker(
            serial: FakeHelperDevice.serial, socketPath: socket, dexSha256: dexSha256,
            limits: HelperBroker.Limits(idle: idle, healthInterval: .seconds(60), pingTimeout: pingTimeout, maxClients: maxClients, failureLinger: .seconds(1)),
            startHelper: {
                if startDelay > .zero { try await Task.sleep(for: startDelay) }
                return try await HelperSessionTests.start(device)
            },
            admits: { _ in true },
            log: { _, _ in }
        )
    }

    /// The folder goes with the fixture, however its test ends.
    deinit { try? FileManager.default.removeItem(at: root) }

    var socket: String { broker.socketPath }

    /// Starts serving and returns once the socket answers.
    func start() async throws {
        running = Task { [broker] in try await broker.run() }
        let deadline = ContinuousClock.now + .seconds(5)
        while !UnixSocket.answers(socket) {
            guard ContinuousClock.now < deadline else { throw HelperBrokerUnavailable(detail: "the broker never listened") }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    /// Returns once the broker's status says its helper is ready.
    func untilReady() async throws {
        _ = try await status(showing: "its helper ready") { $0.state == .ready }
    }

    /// The broker's first status that passes `check`, which `description` names.
    func status(showing description: String, where check: (HelperBrokerWire.Status) -> Bool) async throws -> HelperBrokerWire.Status {
        let deadline = ContinuousClock.now + .seconds(5)
        while true {
            if let status = await HelperBrokerClient.status(at: socket), check(status) { return status }
            guard ContinuousClock.now < deadline else { throw HelperBrokerUnavailable(detail: "the broker's status never showed \(description)") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    /// Returns once the helper has received `op`, so a request sent next waits behind it.
    func untilHelperReceived(_ op: String) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !device.ops.contains(op) {
            guard ContinuousClock.now < deadline else { throw HelperBrokerUnavailable(detail: "the helper never received \(op)") }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    /// A command's client; it never spawns a broker, so a test sees when one would have been started.
    func client(idleSeconds: Int? = nil) throws -> HelperBrokerClient {
        try HelperBrokerClient(
            serial: FakeHelperDevice.serial, dexSha256: FakeHelperDevice.dex.sha256, idleSeconds: idleSeconds ?? Int(idle.components.seconds),
            host: try brokerHost(), log: { _, _ in }
        )
    }

    /// What a command's host needs to reach this broker; it never spawns one.
    func brokerHost() throws -> HelperBrokerHost {
        let lockRoot = root.appendingPathComponent("l").path
        try FileManager.default.createDirectory(atPath: lockRoot, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let directory = self.directory
        return HelperBrokerHost(
            directory: { directory },
            spawn: { [weak self] _, _ in
                MainActor.assumeIsolated { self?.spawns += 1 }
                throw HelperBrokerUnavailable(detail: "no spawning in tests")
            },
            exitStatus: { _ in nil },
            lockRoot: lockRoot
        )
    }

    /// Waits for `run` to return, failing after `timeout`.
    func finished(within timeout: Duration = .seconds(5)) async throws -> Bool {
        guard let running else { return true }
        let deadline = ContinuousClock.now + timeout
        while UnixSocket.answers(socket) || FileManager.default.fileExists(atPath: socket) {
            guard ContinuousClock.now < deadline else { return false }
            try await Task.sleep(for: .milliseconds(10))
        }
        try await running.value
        return true
    }

    func stop() async throws {
        broker.requestStop()
        _ = try await finished()
    }
}

/// Runs a test body in an exit test's child, recording what it throws, which the parent would otherwise see only as SIGTRAP.
@MainActor
func recordingErrors(sourceLocation: SourceLocation = #_sourceLocation, _ body: @MainActor () async throws -> Void) async {
    do {
        try await body()
    } catch is ExpectationFailedError {
        // `#require` has already recorded it.
    } catch {
        Issue.record(error, sourceLocation: sourceLocation)
    }
}

// Tests serving a broker run in a child process, as a broker has its own; in this one the other suites hold up the main actor it serves on.
@Suite("Android warm helper broker")
@MainActor
struct HelperBrokerTests {
    @Test("two commands share one warm helper, and neither quits it")
    func commandsShareOneHelper() async {
        await #expect(processExitsWith: .success) { @MainActor in
            await recordingErrors {
                let fixture = BrokerFixture()
                try await fixture.start()

                let first = try await HelperSession.attach(try fixture.client(), log: { _, _ in })
                _ = try await first.dump()
                await first.close()
                let second = try await HelperSession.attach(try fixture.client(), log: { _, _ in })
                _ = try await second.dump()
                await second.close()

                #expect(fixture.device.startedProcesses == 1)
                #expect(!fixture.device.ops.contains("quit"))
                #expect(fixture.device.ops.filter { $0 == "dump" }.count == 2)
                #expect(first.isWarm && second.isWarm)
                #expect(fixture.spawns == 0)
                try await fixture.stop()
                #expect(fixture.device.ops.last == "quit")
            }
        }
    }

    @Test("a new command's event cursor starts at the helper's latest event, so older events are not new")
    func cursorStartsAtLatestEvent() async {
        await #expect(processExitsWith: .success) { @MainActor in
            await recordingErrors {
                let device = FakeHelperDevice()
                device.answer = { _, op, _ in op == "ping" ? .ok(#"{"eventSeq":42}"#) : nil }
                let fixture = BrokerFixture(device: device)
                try await fixture.start()

                let session = try await HelperSession.attach(try fixture.client(), log: { _, _ in })
                #expect(session.eventCursor == 42)
                #expect(session.ready.pid == 4001)
                await session.close()
                try await fixture.stop()
            }
        }
    }

    @Test("a busy UiAutomation slot reaches the command as busy, so it never falls back to uiautomator")
    func busyStartIsBusy() async {
        await #expect(processExitsWith: .success) { @MainActor in
            await recordingErrors {
                let device = FakeHelperDevice(starts: [.exit(status: 4, stdout: #"{"ok":false,"error":{"code":"busy","message":"UiAutomation is busy","detail":"UiAutomationService already registered"}}"# + "\n")])
                let fixture = BrokerFixture(device: device)
                try await fixture.start()

                await #expect(throws: HelperStartFailure.busy(detail: "UiAutomationService already registered")) {
                    _ = try await HelperSession.attach(try fixture.client(), log: { _, _ in })
                }
                #expect(try await fixture.finished())
            }
        }
    }

    @Test("an unavailable helper keeps its reason, so the command falls back as it would with its own")
    func unavailableKeepsReason() async {
        await #expect(processExitsWith: .success) { @MainActor in
            await recordingErrors {
                let device = FakeHelperDevice(starts: [.exit(status: 3, stdout: #"{"ok":false,"error":{"code":"hidden-api","message":"UiAutomationConnection is not reachable"}}"# + "\n")])
                let fixture = BrokerFixture(device: device)
                try await fixture.start()

                await #expect(throws: HelperStartFailure.unavailable(.hiddenAPI("UiAutomationConnection is not reachable"))) {
                    _ = try await HelperSession.attach(try fixture.client(), log: { _, _ in })
                }
                #expect(try await fixture.finished())
            }
        }
    }

    @Test("the broker stops after its idle timeout, and the helper gets quit")
    func idleTimeoutStops() async {
        await #expect(processExitsWith: .success) { @MainActor in
            await recordingErrors {
                let fixture = BrokerFixture(idle: .milliseconds(300))
                try await fixture.start()
                let session = try await HelperSession.attach(try fixture.client(), log: { _, _ in })
                _ = try await session.dump()
                await session.close()

                #expect(try await fixture.finished(within: .seconds(5)))
                #expect(fixture.device.ops.last == "quit")
            }
        }
    }

    @Test("status and stop never count as use, and stop frees the slot before the socket goes")
    func statusThenStop() async {
        await #expect(processExitsWith: .success) { @MainActor in
            await recordingErrors {
                let fixture = BrokerFixture()
                try await fixture.start()
                let session = try await HelperSession.attach(try fixture.client(), log: { _, _ in })
                await session.close()

                let status = try #require(await HelperBrokerClient.status(at: fixture.socket))
                #expect(status.serial == FakeHelperDevice.serial)
                #expect(status.state == .ready)
                #expect(status.helperPid == 4001)
                #expect(await HelperBrokerClient.stop(at: fixture.socket))
                #expect(!UnixSocket.answers(fixture.socket))
                #expect(fixture.device.ops.last == "quit")
                #expect(try await fixture.finished())
            }
        }
    }

    @Test("a broker of another build is stopped, and the command is told to start its own")
    func otherBuildIsReplaced() async {
        await #expect(processExitsWith: .success) { @MainActor in
            await recordingErrors {
                let fixture = BrokerFixture(dexSha256: String(repeating: "0", count: 64))
                try await fixture.start()

                let found = try await fixture.client().existing(helloID: 1)
                #expect(found == nil)
                #expect(try await fixture.finished())
                #expect(fixture.device.ops.last == "quit")
            }
        }
    }

    @Test("a quit from a command is refused and the warm helper keeps serving")
    func quitIsRefused() async {
        await #expect(processExitsWith: .success) { @MainActor in
            await recordingErrors {
                let fixture = BrokerFixture()
                try await fixture.start()

                let reply = try #require(await HelperBrokerClient.control("quit", at: fixture.socket))
                #expect(String(decoding: reply, as: UTF8.self).contains(#""ok":false"#))
                let session = try await HelperSession.attach(try fixture.client(), log: { _, _ in })
                _ = try await session.dump()
                await session.close()
                #expect(fixture.device.ops.filter { $0 == "quit" }.isEmpty)
                try await fixture.stop()
            }
        }
    }

    @Test("a helper that dies mid-command ends the broker, and the command reports it crashed")
    func lostHelperEndsBroker() async {
        await #expect(processExitsWith: .success) { @MainActor in
            await recordingErrors {
                let device = FakeHelperDevice()
                device.answer = { _, op, _ in op == "dump" ? .hangUp : nil }
                let fixture = BrokerFixture(device: device)
                try await fixture.start()
                let session = try await HelperSession.attach(try fixture.client(), log: { _, _ in })

                await #expect(throws: AndroidError.self) { _ = try await session.dump() }
                #expect(try await fixture.finished())
                await session.close()
            }
        }
    }

    @Test("a command silent past the idle timeout is told idle before the broker stops, so it restarts without counting a loss")
    func silentClientHearsIdle() async {
        await #expect(processExitsWith: .success) { @MainActor in
            await recordingErrors {
                let fixture = BrokerFixture(idle: .milliseconds(1500))
                try await fixture.start()
                let stream = try #require(await HelperBrokerClient.open(fixture.socket))
                let connection = HelperConnection(shell: nil, socket: stream, ready: HelperBrokerClient.unknownReady)
                guard case .reply = try await connection.exchange(.hello(token: ""), id: 1, timeout: .seconds(5)) else {
                    Issue.record("no hello reply")
                    return
                }
                try await Task.sleep(for: .seconds(1))

                let outcome = try await connection.exchange(.ping, id: 2, timeout: .seconds(5))
                #expect(outcome == .bye(reason: "idle", detail: "no request within 0.75 seconds"))
                await connection.close()
                #expect(try await fixture.finished())
            }
        }
    }

    @Test("a broker started with another idle timeout is replaced, so the command's own setting holds")
    func otherIdleIsReplaced() async {
        await #expect(processExitsWith: .success) { @MainActor in
            await recordingErrors {
                let fixture = BrokerFixture(idle: .seconds(30))
                try await fixture.start()

                let found = try await fixture.client(idleSeconds: 5).existing(helloID: 1)
                #expect(found == nil)
                #expect(try await fixture.finished())
            }
        }
    }

    @Test("a warm command's requests carry its timeout, so the broker gives up on the helper when the command does")
    func requestsCarryTheirTimeout() async {
        await #expect(processExitsWith: .success) { @MainActor in
            await recordingErrors {
                let fixture = BrokerFixture()
                try await fixture.start()
                let session = try await HelperSession.attach(try fixture.client(), log: { _, _ in })
                _ = try await session.dump()
                await session.close()

                let dump = try #require(fixture.device.frames.first { $0.op == "dump" })
                #expect(dump.json.contains(#""brokerTimeoutMs":15000"#))
                try await fixture.stop()
            }
        }
    }

    @Test("the relay waits as long as the command does, never longer than the cap", arguments: [
        (#"{"id":1,"op":"dump","brokerTimeoutMs":15000}"#, Duration.seconds(15)),
        (#"{"id":1,"op":"dump","brokerTimeoutMs":900000}"#, .seconds(60)),
        (#"{"id":1,"op":"events","waitMs":2000}"#, .seconds(7)),
        (#"{"id":1,"op":"dump"}"#, .seconds(60)),
    ])
    func relayTimeouts(request: String, expected: Duration) throws {
        let parsed = try #require(HelperBrokerWire.Request.parse(Data(request.utf8)))
        #expect(HelperBroker.relayTimeout(for: parsed, cap: .seconds(60)) == expected)
    }

    @Test("status counts the commands attached, which a command reading another way waits on before it stops the helper")
    func statusCountsAttached() async {
        await #expect(processExitsWith: .success) { @MainActor in
            await recordingErrors {
                let fixture = BrokerFixture()
                try await fixture.start()
                let session = try await HelperSession.attach(try fixture.client(), log: { _, _ in })

                #expect(await HelperBrokerClient.status(at: fixture.socket)?.attached == 1)
                await session.close()
                let idle = try await fixture.status(showing: "no command attached") { $0.attached == 0 }
                #expect(idle.protocol == 2 && idle.sdkInt == 36 && idle.helper == "1.0.0")
                try await fixture.stop()
            }
        }
    }

    @Test("a command over the client limit is refused with its own request id")
    func refusalAnswersTheRequest() async {
        await #expect(processExitsWith: .success) { @MainActor in
            await recordingErrors {
                let fixture = BrokerFixture(maxClients: 1)
                try await fixture.start()
                // The start's probe must have gone before the one client allowed attaches; a status that answers shows the slot free.
                let free = ContinuousClock.now + .seconds(5)
                while await HelperBrokerClient.status(at: fixture.socket) == nil, ContinuousClock.now < free {
                    try await Task.sleep(for: .milliseconds(20))
                }
                let session = try await HelperSession.attach(try fixture.client(), log: { _, _ in })

                let stream = try #require(await HelperBrokerClient.open(fixture.socket))
                let connection = HelperConnection(shell: nil, socket: stream, ready: HelperBrokerClient.unknownReady)
                let outcome = try await connection.exchange(.ping, id: 42, timeout: .seconds(5))
                guard case .reply(let frame) = outcome else {
                    Issue.record("no reply to the refused request: \(outcome)")
                    return
                }
                let reply = try JSONDecoder().decode(HelperBrokerWire.ErrorReply.self, from: frame)
                #expect(reply.error.code == HelperBrokerWire.Code.refused)
                await connection.close()
                await session.close()
                try await fixture.stop()
            }
        }
    }

    @Test("doctor reads a ready warm helper from status, and reports one still starting as unavailable")
    func doctorReadsStatus() {
        func status(_ state: HelperBrokerWire.Status.State) -> HelperBrokerWire.Status {
            HelperBrokerWire.Status(
                serial: FakeHelperDevice.serial, state: state, brokerPid: 10, helperPid: state == .ready ? 4001 : nil, startedAt: 0,
                idleSeconds: 60, idleFor: 3, attached: 0, helper: state == .ready ? "1.6.0" : nil, protocol: state == .ready ? 2 : nil,
                sdkInt: state == .ready ? 36 : nil, launchMs: state == .ready ? 112 : nil, pushed: state == .ready ? false : nil
            )
        }
        #expect(AndroidDoctorProbe.warmHelperFact(status(.ready), helloMilliseconds: 2, health: .answered(milliseconds: 2)) == .ready(
            launchMilliseconds: 112, pushed: false, helloMilliseconds: 2, pingMilliseconds: 2, protocolVersion: 2, sdkInt: 36
        ))
        #expect(AndroidDoctorProbe.warmHelperFact(status(.starting), helloMilliseconds: 2, health: nil) == .unavailable("the warm helper is starting"))
        #expect(AndroidDoctorProbe.warmHelperFact(status(.ready), helloMilliseconds: 2, health: nil) == .unavailable("the warm helper did not answer its ping"))
        #expect(AndroidDoctorProbe.warmHelperFact(status(.ready), helloMilliseconds: 2, health: .busy) == .ready(
            launchMilliseconds: 112, pushed: false, helloMilliseconds: 2, pingMilliseconds: nil, protocolVersion: 2, sdkInt: 36
        ))
    }

    @Test("input whose command has gone is never sent")
    func goneInputIsDropped() async {
        await #expect(processExitsWith: .success) { @MainActor in
            await recordingErrors {
                let fixture = BrokerFixture()
                try await fixture.start()
                let stream = try #require(await HelperBrokerClient.open(fixture.socket))
                let inject = try HelperRequest.inject([], sync: true).payload(id: 7)
                try await stream.write(try HelperWire.frame(inject), deadline: .now + .seconds(2))
                await stream.close()
                try await Task.sleep(for: .milliseconds(200))

                #expect(!fixture.device.ops.contains("inject"))
                try await fixture.stop()
            }
        }
    }

    @Test("input queued behind another command's slow request is dropped unsent once its command has gone, so a late tap never lands")
    func queuedInputOfGoneCommandIsDropped() async {
        await #expect(processExitsWith: .success) { @MainActor in
            await recordingErrors {
                let device = FakeHelperDevice()
                device.answer = { _, op, _ in op == "dump" ? .okAfter(FakeHelperDevice.tapTestDump, .milliseconds(800)) : nil }
                let fixture = BrokerFixture(device: device)
                try await fixture.start()
                let reader = try await HelperSession.attach(try fixture.client(), log: { _, _ in })
                let slow = Task { _ = try await reader.dump() }
                try await fixture.untilHelperReceived("dump")

                let stream = try #require(await HelperBrokerClient.open(fixture.socket))
                let inject = try HelperRequest.inject([], sync: true).adding(HelperBrokerWire.timeoutField, .int(5000)).payload(id: 7)
                try await stream.write(try HelperWire.frame(inject), deadline: .now + .seconds(2))
                try await Task.sleep(for: .milliseconds(200))
                await stream.close()
                try await slow.value
                // Queued after the input, so the input's turn has passed once it answers.
                try await reader.ping()

                #expect(!fixture.device.ops.contains("inject"))
                await reader.close()
                try await fixture.stop()
            }
        }
    }

    @Test("a request still queued when its command's timeout passes is refused unsent, and the helper keeps serving")
    func lateRequestIsRefusedUnsent() async {
        await #expect(processExitsWith: .success) { @MainActor in
            await recordingErrors {
                let device = FakeHelperDevice()
                device.answer = { _, op, _ in op == "dump" ? .okAfter(FakeHelperDevice.tapTestDump, .milliseconds(800)) : nil }
                let fixture = BrokerFixture(device: device)
                try await fixture.start()
                let reader = try await HelperSession.attach(try fixture.client(), log: { _, _ in })
                let slow = Task { _ = try await reader.dump() }
                try await fixture.untilHelperReceived("dump")

                let stream = try #require(await HelperBrokerClient.open(fixture.socket))
                let connection = HelperConnection(shell: nil, socket: stream, ready: HelperBrokerClient.unknownReady)
                let display = HelperRequest.display.adding(HelperBrokerWire.timeoutField, .int(300))
                let outcome = try await connection.exchange(display, id: 9, timeout: .seconds(5))
                guard case .reply(let frame) = outcome else {
                    Issue.record("no reply to the late request: \(outcome)")
                    return
                }
                #expect(try JSONDecoder().decode(HelperBrokerWire.ErrorReply.self, from: frame).error.code == HelperBrokerWire.Code.refused)
                try await slow.value

                #expect(!fixture.device.ops.contains("display"))
                #expect(await HelperBrokerClient.status(at: fixture.socket)?.state == .ready)
                await connection.close()
                await reader.close()
                try await fixture.stop()
            }
        }
    }

    @Test("a request's turn drops it when its command has gone or given up, and input that waited long enough to land late", arguments: [
        ("inject", true, Duration.milliseconds(10), Duration.seconds(5), HelperBroker.Unsent.gone),
        ("inject", false, .milliseconds(4500), .seconds(25), .late(waited: .milliseconds(4500))),
        ("inject", false, .seconds(3), .seconds(5), nil),
        ("dump", false, .seconds(16), .seconds(15), .late(waited: .seconds(16))),
        ("dump", true, .seconds(1), .seconds(15), nil),
        ("dump", false, .seconds(3), .seconds(15), nil),
        ("inject", false, .seconds(1), .seconds(5), nil),
    ] as [(String, Bool, Duration, Duration, HelperBroker.Unsent?)])
    func unsentRules(op: String, peerClosed: Bool, waited: Duration, timeout: Duration, expected: HelperBroker.Unsent?) {
        #expect(HelperBroker.unsent(op: op, peerClosed: peerClosed, waited: waited, timeout: timeout) == expected)
    }

    @Test("a broker with another idle timeout is stopped only once free, so a command that attached after the hello is never cut off")
    func otherIdleWaitsForFree() async {
        await #expect(processExitsWith: .success) { @MainActor in
            await recordingErrors {
                let fixture = BrokerFixture()
                let dex = FakeHelperDevice.dex.sha256
                let busy = #"{"serial":"emulator-5556","state":"ready","brokerPid":3,"attached":1}"#
                let broker = try ScriptedBroker(path: fixture.socket, status: busy, hello: { id in
                    HelperBrokerWire.helloReply(id: id, helper: "1.5.0", protocol: HelperDex.protocolVersion, ops: ["dump"], broker: HelperBrokerWire.Hello(
                        brokerProtocol: HelperBrokerWire.protocolVersion, brokerPid: 3, dexSha256: dex, helperPid: 4001, sdkInt: 36, idleSeconds: 30,
                        launchMs: 100, pushed: false, eventSeq: 0, attached: 0
                    ))
                })
                var client = try fixture.client(idleSeconds: 5)
                client.freeWait = .milliseconds(300)

                #expect(try await client.existing(helloID: 1) == nil)
                #expect(broker.ops.contains("hello") && !broker.ops.contains("stop"))
                broker.cancel()
            }
        }
    }

    @Test("a broker that does not report its commands is left running by a stop that waits for it to be free")
    func unknownAttachedIsInUse() async {
        await #expect(processExitsWith: .success) { @MainActor in
            await recordingErrors {
                let fixture = BrokerFixture()
                let broker = try ScriptedBroker(path: fixture.socket, status: #"{"serial":"emulator-5556","state":"ready","brokerPid":3}"#)

                #expect(await HelperBrokerClient.stopWhenFree(at: fixture.socket, wait: .milliseconds(300)) == .inUse)
                #expect(!broker.ops.contains("stop"))
                broker.cancel()
            }
        }
    }

    final class Asked: @unchecked Sendable {
        private let lock = NSLock()
        private var arguments: [[String]] = []
        func record(_ value: [String]) { lock.withLock { arguments.append(value) } }
        var all: [[String]] { lock.withLock { arguments } }
    }

    @Test("a broker that closes before a byte, as another build's does, is looked up by its arguments before the command starts its own")
    func refusingBrokerIsLookedUp() async {
        await #expect(processExitsWith: .success) { @MainActor in
            await recordingErrors {
                let fixture = BrokerFixture()
                // No hello reply: the scripted broker closes the connection unread, as a broker of another build does.
                let broker = try ScriptedBroker(path: fixture.socket)
                var client = try fixture.client()
                let asked = Asked()
                let socket = fixture.socket
                client.stopOtherBuilds = { arguments, path in
                    asked.record(arguments + [path])
                    return []
                }
                let connection = try await client.existing(helloID: 1)
                #expect(connection == nil)
                #expect(asked.all == [["android-session", "serve", "--device", FakeHelperDevice.serial, socket]])
                broker.cancel()
            }
        }
    }

    @Test("a stop while the helper is still starting returns once the start has ended and the slot is free, never before")
    func stopWhileStartingWaitsForTheStart() async {
        await #expect(processExitsWith: .success) { @MainActor in
            await recordingErrors {
                let fixture = BrokerFixture(startDelay: .milliseconds(3500))
                try await fixture.start()

                #expect(await HelperBrokerClient.stop(at: fixture.socket))
                #expect(!UnixSocket.answers(fixture.socket))
                #expect(fixture.device.ops.last == "quit")
                #expect(try await fixture.finished())
            }
        }
    }

    @Test("health pings the warm helper itself, so a helper that stopped answering never looks ready")
    func healthPingsTheHelper() async {
        await #expect(processExitsWith: .success) { @MainActor in
            await recordingErrors {
                let healthy = BrokerFixture()
                try await healthy.start()
                try await healthy.untilReady()
                #expect(await HelperBrokerClient.health(at: healthy.socket) != nil)
                #expect(healthy.device.ops.last == "ping")
                try await healthy.stop()

                let device = FakeHelperDevice()
                device.answer = { _, op, _ in op == "ping" ? .silence : nil }
                let wedged = BrokerFixture(device: device)
                try await wedged.start()
                try await wedged.untilReady()
                #expect(await HelperBrokerClient.health(at: wedged.socket) == nil)
                #expect(try await wedged.finished())
            }
        }
    }

    @Test("a ping queued behind another command's slow request still gets its full time, so a new command attaches and the helper stays")
    func queuedPingKeepsTheHelper() async {
        await #expect(processExitsWith: .success) { @MainActor in
            await recordingErrors {
                let device = FakeHelperDevice()
                device.answer = { _, op, _ in
                    switch op {
                    case "dump": .okAfter(FakeHelperDevice.tapTestDump, .milliseconds(800))
                    case "ping": .okAfter("{}", .milliseconds(100))
                    default: nil
                    }
                }
                let fixture = BrokerFixture(device: device, pingTimeout: .milliseconds(300))
                try await fixture.start()
                let reader = try await HelperSession.attach(try fixture.client(), log: { _, _ in })
                let slow = Task { _ = try await reader.dump() }
                try await fixture.untilHelperReceived("dump")

                let second = try await HelperSession.attach(try fixture.client(), log: { _, _ in })
                try await slow.value
                #expect(second.isWarm)
                #expect(await HelperBrokerClient.status(at: fixture.socket)?.state == .ready)
                #expect(fixture.device.startedProcesses == 1)
                await second.close()
                await reader.close()
                try await fixture.stop()
            }
        }
    }

    @Test("health answers busy at once while a command's request runs on the helper, instead of a ping that waits behind it")
    func healthWhileBusyAnswersAtOnce() async {
        await #expect(processExitsWith: .success) { @MainActor in
            await recordingErrors {
                let device = FakeHelperDevice()
                device.answer = { _, op, _ in op == "dump" ? .okAfter(FakeHelperDevice.tapTestDump, .milliseconds(1500)) : nil }
                let fixture = BrokerFixture(device: device)
                try await fixture.start()
                let reader = try await HelperSession.attach(try fixture.client(), log: { _, _ in })
                let slow = Task { _ = try await reader.dump() }
                try await fixture.untilHelperReceived("dump")

                let asked = ContinuousClock.now
                #expect(await HelperBrokerClient.health(at: fixture.socket) == .busy)
                #expect(ContinuousClock.now - asked < .milliseconds(700))
                try await slow.value
                #expect(await HelperBrokerClient.status(at: fixture.socket)?.state == .ready)
                await reader.close()
                try await fixture.stop()
            }
        }
    }

    @Test("a broker whose status does not read is left running by a stop that waits for it to be free")
    func unreadableStatusIsInUse() async {
        await #expect(processExitsWith: .success) { @MainActor in
            await recordingErrors {
                let fixture = BrokerFixture()
                let broker = try ScriptedBroker(path: fixture.socket)

                #expect(await HelperBrokerClient.stopWhenFree(at: fixture.socket, wait: .milliseconds(300)) == .inUse)
                #expect(!broker.ops.contains("stop"))
                broker.cancel()
            }
        }
    }

    @Test("a stop returns once its broker's socket goes, even when another broker takes the path at once")
    func stopEndsWhenAnotherBrokerTakesThePath() async {
        await #expect(processExitsWith: .success) { @MainActor in
            await recordingErrors {
                let fixture = BrokerFixture()
                let broker = try ScriptedBroker(path: fixture.socket, replaceOnStop: true)

                let asked = ContinuousClock.now
                #expect(await HelperBrokerClient.stop(at: fixture.socket))
                #expect(ContinuousClock.now - asked < .milliseconds(1500))
                #expect(UnixSocket.answers(fixture.socket))
                broker.cancel()
            }
        }
    }

    @Test("the relay cap outlasts the longest inject a command sends, so a full-length gesture is never cut off")
    func relayCapOutlastsLongestInject() {
        let longest = HelperSession.requestTimeout + .milliseconds(HelperInjectPlan.maxRequestMilliseconds)
        #expect(HelperBroker.Limits(idle: .seconds(60)).relayTimeout > longest)
    }

    @Test("a request whose turn comes with almost no time left still gets its reply, and the helper is not taken as wedged")
    func lateTurnKeepsHealthyHelper() async {
        await #expect(processExitsWith: .success) { @MainActor in
            await recordingErrors {
                let device = FakeHelperDevice()
                device.answer = { _, op, _ in
                    switch op {
                    case "dump": .okAfter(FakeHelperDevice.tapTestDump, .milliseconds(800))
                    case "display": .okAfter(FakeHelperDevice.displayReply, .milliseconds(600))
                    default: nil
                    }
                }
                let fixture = BrokerFixture(device: device)
                try await fixture.start()
                let reader = try await HelperSession.attach(try fixture.client(), log: { _, _ in })
                let slow = Task { _ = try await reader.dump() }
                try await fixture.untilHelperReceived("dump")

                let stream = try #require(await HelperBrokerClient.open(fixture.socket))
                let connection = HelperConnection(shell: nil, socket: stream, ready: HelperBrokerClient.unknownReady)
                let display = HelperRequest.display.adding(HelperBrokerWire.timeoutField, .int(1100))
                let outcome = try await connection.exchange(display, id: 9, timeout: .seconds(5))
                try await slow.value

                guard case .reply(let frame) = outcome else {
                    Issue.record("no reply to the late turn: \(outcome)")
                    return
                }
                #expect(HelperBrokerWire.isOK(frame))
                #expect(await HelperBrokerClient.status(at: fixture.socket)?.state == .ready)
                await connection.close()
                await reader.close()
                try await fixture.stop()
            }
        }
    }

    @Test("a broker that answers but does not stop is reported as still serving, never as stopped")
    func unstoppableBrokerIsNotStopped() async {
        await #expect(processExitsWith: .success) { @MainActor in
            await recordingErrors {
                let fixture = BrokerFixture()
                let free = #"{"serial":"emulator-5556","state":"ready","brokerPid":3,"attached":0}"#
                let other = try ScriptedBroker(path: fixture.socket, status: free, answersStop: false)

                #expect(await HelperBrokerClient.stopWhenFree(at: fixture.socket, wait: .milliseconds(200)) == .stillServing)
                #expect(UnixSocket.answers(fixture.socket))
                other.cancel()
            }
        }
    }

    @Test("a broker with another idle timeout that serves another command is kept, so neither command cuts the other off")
    func otherIdleInUseIsKept() async {
        await #expect(processExitsWith: .success) { @MainActor in
            await recordingErrors {
                let fixture = BrokerFixture(idle: .seconds(30))
                try await fixture.start()
                let first = try await HelperSession.attach(try fixture.client(), log: { _, _ in })

                let second = try #require(try await fixture.client(idleSeconds: 5).existing(helloID: 1))
                #expect(await HelperBrokerClient.status(at: fixture.socket)?.attached == 2)
                await second.close()
                await first.close()
                #expect(fixture.device.startedProcesses == 1)
                try await fixture.stop()
            }
        }
    }

    @Test("a broker of another build that serves another command is left running, and this command is told to start its own helper")
    func otherBuildInUseIsLeft() async {
        await #expect(processExitsWith: .success) { @MainActor in
            await recordingErrors {
                let fixture = BrokerFixture(dexSha256: String(repeating: "0", count: 64))
                try await fixture.start()
                let stream = try #require(await HelperBrokerClient.open(fixture.socket))
                let other = HelperConnection(shell: nil, socket: stream, ready: HelperBrokerClient.unknownReady)
                guard case .reply = try await other.exchange(.hello(token: ""), id: 1, timeout: .seconds(5)) else {
                    Issue.record("no hello reply")
                    return
                }
                var client = try fixture.client()
                client.freeWait = .milliseconds(300)

                await #expect(throws: HelperBrokerUnavailable.self) { _ = try await client.existing(helloID: 2) }
                #expect(UnixSocket.answers(fixture.socket))
                await other.close()
                try await fixture.stop()
            }
        }
    }

    @Test("past the client and refusal limits a connection is closed unanswered, so a flood cannot pile up work")
    func refusalsAreCapped() async {
        await #expect(processExitsWith: .success) { @MainActor in
            await recordingErrors {
                let fixture = BrokerFixture(maxClients: 1)
                try await fixture.start()
                let free = ContinuousClock.now + .seconds(5)
                while await HelperBrokerClient.status(at: fixture.socket) == nil, ContinuousClock.now < free {
                    try await Task.sleep(for: .milliseconds(20))
                }
                let session = try await HelperSession.attach(try fixture.client(), log: { _, _ in })
                // Refused but silent, it holds the one refusal slot while the broker waits for its request.
                let silent = try #require(await HelperBrokerClient.open(fixture.socket))
                try await Task.sleep(for: .milliseconds(300))

                let stream = try #require(await HelperBrokerClient.open(fixture.socket))
                let connection = HelperConnection(shell: nil, socket: stream, ready: HelperBrokerClient.unknownReady)
                let outcome = try await connection.exchange(.ping, id: 42, timeout: .seconds(5))
                guard case .lost = outcome else {
                    Issue.record("answered past the refusal limit: \(outcome)")
                    return
                }
                await connection.close()
                await silent.close()
                await session.close()
                try await fixture.stop()
            }
        }
    }

    @Test("a status from another build missing newer fields still reads, so session stop finds its broker")
    func statusReadsLeniently() throws {
        let frame = Data(#"{"id":1,"ok":true,"status":{"serial":"emulator-5556","state":"ready","brokerPid":12}}"#.utf8)
        let status = try JSONDecoder().decode(HelperBrokerWire.StatusReply.self, from: frame).status
        #expect(status.serial == "emulator-5556")
        #expect(status.attached == nil && status.helperPid == nil)
    }

    @Test("session stop stops a broker whose status does not read, named by the serial it gives or its log names", arguments: [
        (#"{"serial":"emulator-5556","state":"draining"}"#, nil),
        (#"{"state":"draining"}"#, "2026-10-18T09:00:00Z Serving emulator-5556 on /tmp/s/android-x.sock\n"),
    ] as [(String, String?)])
    func stopsUnreadableBroker(status: String, log: String?) async {
        await #expect(processExitsWith: .success) { @MainActor [status, log] in
            await recordingErrors {
                let fixture = BrokerFixture()
                let other = try ScriptedBroker(path: fixture.socket, status: status)
                if let log {
                    try log.write(toFile: (fixture.socket as NSString).deletingPathExtension + ".log", atomically: true, encoding: .utf8)
                }
                var host = AndroidTestHost.make()
                host.helperBroker = try fixture.brokerHost()

                let stopped = await AndroidBackend.stopWarmHelpers(host: host)
                #expect(stopped == ["emulator-5556"])
                #expect(!UnixSocket.answers(fixture.socket))
                other.cancel()
            }
        }
    }
}

/// A broker answering `status` and `hello` as scripted (by default a status this build cannot read), recording each op; `stop` closes it unless it ignores stops.
@MainActor
final class ScriptedBroker {
    private let listener: UnixSocketListener
    private var serving: Task<Void, Never>?
    private(set) var ops: [String] = []
    /// The broker that took the path when this one stopped, moved over the old socket so the path never goes.
    private var replacement: UnixSocketListener?

    init(
        path: String, status: String = #"{"state":"draining"}"#, hello: (@Sendable (Int) -> Data)? = nil, answersStop: Bool = true,
        replaceOnStop: Bool = false
    ) throws {
        let listener = try UnixSocketListener(path: path, admits: { _ in true })
        self.listener = listener
        serving = Task { [weak self] in
            while !Task.isCancelled {
                guard let descriptor = await listener.accept(timeout: .milliseconds(50)) else { continue }
                let stream = PosixAdbStream.adopting(descriptor)
                var decoder = HelperWire.FrameDecoder()
                let chunk = (try? await stream.read(upTo: 64 * 1024, deadline: .now + .seconds(2))) ?? Data()
                guard let request = (try? decoder.feed(chunk))?.first.flatMap(HelperBrokerWire.Request.parse) else {
                    await stream.close()
                    continue
                }
                self?.ops.append(request.op)
                if request.op == "stop", !answersStop {
                    await stream.close()
                    continue
                }
                let reply = request.op == "hello" ? hello?(request.id)
                    : Data((request.op == "status" ? #"{"id":\#(request.id),"ok":true,"status":\#(status)}"# : #"{"id":\#(request.id),"ok":true}"#).utf8)
                if let reply, let frame = try? HelperWire.frame(reply) {
                    try? await stream.write(frame, deadline: .now + .seconds(2))
                }
                await stream.close()
                if request.op == "stop" {
                    if replaceOnStop, let fresh = try? UnixSocketListener(path: path + ".new", admits: { _ in true }) {
                        rename(path + ".new", path)
                        self?.replacement = fresh
                    }
                    listener.close()
                    return
                }
            }
        }
    }

    func cancel() {
        serving?.cancel()
        listener.close()
        replacement?.close()
    }
}

@Suite("Android warm helper settings")
struct HelperBrokerSettingsTests {
    @Test("emulators keep the helper warm by default, phones only with on, nothing with off")
    func warmByDevice() {
        #expect(HelperBrokerSettings.keepsWarm(.auto, isEmulator: true))
        #expect(!HelperBrokerSettings.keepsWarm(.auto, isEmulator: false))
        #expect(HelperBrokerSettings.keepsWarm(.on, isEmulator: false))
        #expect(!HelperBrokerSettings.keepsWarm(.off, isEmulator: true))
    }

    @Test("only an emulator-NNNN serial counts as an emulator")
    func emulatorSerials() {
        #expect(HelperBrokerSettings.isEmulatorSerial("emulator-5554"))
        #expect(!HelperBrokerSettings.isEmulatorSerial("R5CT1234ABC"))
        #expect(!HelperBrokerSettings.isEmulatorSerial("emulator-"))
    }

    @Test("the idle timeout is 60 s unless set to a positive number, and at most an hour", arguments: [
        (nil, 60), ("5", 5), ("0", 60), ("-3", 60), ("soon", 60), ("7200", 3600),
    ] as [(String?, Int)])
    func idleSeconds(value: String?, expected: Int) {
        let environment = value.map { [HelperBrokerSettings.idleVariable: $0] } ?? [:]
        #expect(HelperBrokerSettings.idleSeconds(environment) == expected)
    }

    @Test("an unknown OFFSIDER_ANDROID_SESSION value is refused, naming the choices")
    func unknownMode() throws {
        let host = AndroidTestHost.make(environment: [HelperBrokerSettings.modeVariable: "sometimes"])
        #expect(throws: AndroidError.invalidSetting(variable: HelperBrokerSettings.modeVariable, value: "sometimes", expected: "auto, on or off")) {
            try HelperBrokerSettings.mode(host: host)
        }
        #expect(try HelperBrokerSettings.mode(host: AndroidTestHost.make(environment: [HelperBrokerSettings.modeVariable: "OFF"])) == .off)
    }

    @Test("a start failure crosses the broker with its reason", arguments: [
        HelperStartFailure.busy(detail: "already registered"),
        .unavailable(.pushFailed("no space")), .unavailable(.hiddenAPI("blocked")), .unavailable(.connectFailed("threw")),
        .unavailable(.crashed(status: 6, detail: "boom")), .unavailable(.noReady(seconds: 30)), .unavailable(.handshake("closed")),
        .unavailable(.damaged("mismatch")), .unavailable(.notBundled("none")), .unavailable(.forcedOff),
    ])
    func startFailureRoundTrip(failure: HelperStartFailure) throws {
        let frame = HelperBrokerWire.startFailure(id: 3, failure)
        let reply = try JSONDecoder().decode(HelperBrokerWire.ErrorReply.self, from: frame)
        #expect(reply.startFailure == failure)
    }
}

@Suite("Android warm helper listener")
struct UnixSocketListenerTests {
    @Test("a peer the broker does not admit is closed before it reads a byte, and never reaches the accept loop")
    func refusedPeerReadsNothing() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ol-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("b.sock").path
        let listener = try UnixSocketListener(path: path, admits: { _ in false })
        defer { listener.close() }
        let accepted = Task { await listener.accept(timeout: .seconds(2)) }
        let client = socket(AF_UNIX, SOCK_STREAM, 0)
        try #require(client >= 0)
        defer { Darwin.close(client) }
        var address = try UnixSocket.address(path)
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(client, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        #expect(connected == 0)
        #expect(await accepted.value == nil)
        var byte: UInt8 = 0
        #expect(Darwin.read(client, &byte, 1) == 0)
    }

    @Test("a peer the broker admits reaches the accept loop")
    func admittedPeerIsAccepted() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ol-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("b.sock").path
        let listener = try UnixSocketListener(path: path, admits: { _ in true })
        defer { listener.close() }
        let accepted = Task { await listener.accept(timeout: .seconds(2)) }
        let client = socket(AF_UNIX, SOCK_STREAM, 0)
        try #require(client >= 0)
        defer { Darwin.close(client) }
        var address = try UnixSocket.address(path)
        _ = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(client, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        let served = await accepted.value
        #expect(served != nil)
        if let served { Darwin.close(served) }
    }
}
