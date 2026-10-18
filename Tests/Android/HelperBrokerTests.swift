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
        device: FakeHelperDevice = FakeHelperDevice(), idle: Duration = .seconds(30), dexSha256: String = FakeHelperDevice.dex.sha256, maxClients: Int = 8
    ) {
        self.idle = idle
        self.device = device
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ob-\(UUID().uuidString.prefix(8))")
        directory = root.appendingPathComponent("s").path
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let socket = HelperBrokerPaths(serial: FakeHelperDevice.serial, directory: directory).socket
        broker = HelperBroker(
            serial: FakeHelperDevice.serial, socketPath: socket, dexSha256: dexSha256,
            limits: HelperBroker.Limits(idle: idle, healthInterval: .seconds(60), maxClients: maxClients, failureLinger: .seconds(1)),
            startHelper: { try await HelperSessionTests.start(device) },
            log: { _, _ in }
        )
    }

    var socket: String { broker.socketPath }

    /// Starts serving and returns once the socket answers.
    func start() async throws {
        running = Task { try await broker.run() }
        let deadline = ContinuousClock.now + .seconds(5)
        while !UnixSocket.answers(socket) {
            guard ContinuousClock.now < deadline else { throw HelperBrokerUnavailable(detail: "the broker never listened") }
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
        try? FileManager.default.removeItem(at: root)
    }
}

@Suite("Android warm helper broker")
@MainActor
struct HelperBrokerTests {
    @Test("two commands share one warm helper, and neither quits it")
    func commandsShareOneHelper() async throws {
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

    @Test("a new command's event cursor starts at the helper's latest event, so older events are not new")
    func cursorStartsAtLatestEvent() async throws {
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

    @Test("a busy UiAutomation slot reaches the command as busy, so it never falls back to uiautomator")
    func busyStartIsBusy() async throws {
        let device = FakeHelperDevice(starts: [.exit(status: 4, stdout: #"{"ok":false,"error":{"code":"busy","message":"UiAutomation is busy","detail":"UiAutomationService already registered"}}"# + "\n")])
        let fixture = BrokerFixture(device: device)
        try await fixture.start()

        await #expect(throws: HelperStartFailure.busy(detail: "UiAutomationService already registered")) {
            _ = try await HelperSession.attach(try fixture.client(), log: { _, _ in })
        }
        #expect(try await fixture.finished())
    }

    @Test("an unavailable helper keeps its reason, so the command falls back as it would with its own")
    func unavailableKeepsReason() async throws {
        let device = FakeHelperDevice(starts: [.exit(status: 3, stdout: #"{"ok":false,"error":{"code":"hidden-api","message":"UiAutomationConnection is not reachable"}}"# + "\n")])
        let fixture = BrokerFixture(device: device)
        try await fixture.start()

        await #expect(throws: HelperStartFailure.unavailable(.hiddenAPI("UiAutomationConnection is not reachable"))) {
            _ = try await HelperSession.attach(try fixture.client(), log: { _, _ in })
        }
        #expect(try await fixture.finished())
    }

    @Test("the broker stops after its idle timeout, and the helper gets quit")
    func idleTimeoutStops() async throws {
        let fixture = BrokerFixture(idle: .milliseconds(300))
        try await fixture.start()
        let session = try await HelperSession.attach(try fixture.client(), log: { _, _ in })
        _ = try await session.dump()
        await session.close()

        #expect(try await fixture.finished(within: .seconds(5)))
        #expect(fixture.device.ops.last == "quit")
    }

    @Test("status and stop never count as use, and stop frees the slot before the socket goes")
    func statusThenStop() async throws {
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

    @Test("a broker of another build is stopped, and the command is told to start its own")
    func otherBuildIsReplaced() async throws {
        let fixture = BrokerFixture(dexSha256: String(repeating: "0", count: 64))
        try await fixture.start()

        let found = try await fixture.client().existing(helloID: 1)
        #expect(found == nil)
        #expect(try await fixture.finished())
        #expect(fixture.device.ops.last == "quit")
    }

    @Test("a quit from a command is refused and the warm helper keeps serving")
    func quitIsRefused() async throws {
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

    @Test("a helper that dies mid-command ends the broker, and the command reports it crashed")
    func lostHelperEndsBroker() async throws {
        let device = FakeHelperDevice()
        device.answer = { _, op, _ in op == "dump" ? .hangUp : nil }
        let fixture = BrokerFixture(device: device)
        try await fixture.start()
        let session = try await HelperSession.attach(try fixture.client(), log: { _, _ in })

        await #expect(throws: AndroidError.self) { _ = try await session.dump() }
        #expect(try await fixture.finished())
        await session.close()
    }

    @Test("a command silent past the idle timeout is told idle before the broker stops, so it restarts without counting a loss")
    func silentClientHearsIdle() async throws {
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

    @Test("a broker started with another idle timeout is replaced, so the command's own setting holds")
    func otherIdleIsReplaced() async throws {
        let fixture = BrokerFixture(idle: .seconds(30))
        try await fixture.start()

        let found = try await fixture.client(idleSeconds: 5).existing(helloID: 1)
        #expect(found == nil)
        #expect(try await fixture.finished())
    }

    @Test("a warm command's requests carry its timeout, so the broker gives up on the helper when the command does")
    func requestsCarryTheirTimeout() async throws {
        let fixture = BrokerFixture()
        try await fixture.start()
        let session = try await HelperSession.attach(try fixture.client(), log: { _, _ in })
        _ = try await session.dump()
        await session.close()

        let dump = try #require(fixture.device.frames.first { $0.op == "dump" })
        #expect(dump.json.contains(#""brokerTimeoutMs":15000"#))
        try await fixture.stop()
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
    func statusCountsAttached() async throws {
        let fixture = BrokerFixture()
        try await fixture.start()
        let session = try await HelperSession.attach(try fixture.client(), log: { _, _ in })

        #expect(await HelperBrokerClient.status(at: fixture.socket)?.attached == 1)
        await session.close()
        try await Task.sleep(for: .milliseconds(100))
        let idle = try #require(await HelperBrokerClient.status(at: fixture.socket))
        #expect(idle.attached == 0)
        #expect(idle.protocol == 2 && idle.sdkInt == 36 && idle.helper == "1.0.0")
        try await fixture.stop()
    }

    @Test("a command over the client limit is refused with its own request id")
    func refusalAnswersTheRequest() async throws {
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

    @Test("doctor reads a ready warm helper from status, and reports one still starting as unavailable")
    func doctorReadsStatus() {
        func status(_ state: HelperBrokerWire.Status.State) -> HelperBrokerWire.Status {
            HelperBrokerWire.Status(
                serial: FakeHelperDevice.serial, state: state, brokerPid: 10, helperPid: state == .ready ? 4001 : nil, startedAt: 0,
                idleSeconds: 60, idleFor: 3, attached: 0, helper: state == .ready ? "1.6.0" : nil, protocol: state == .ready ? 2 : nil,
                sdkInt: state == .ready ? 36 : nil, launchMs: state == .ready ? 112 : nil, pushed: state == .ready ? false : nil
            )
        }
        #expect(AndroidDoctorProbe.warmHelperFact(status(.ready), milliseconds: 2) == .ready(
            launchMilliseconds: 112, pushed: false, helloMilliseconds: 2, pingMilliseconds: 2, protocolVersion: 2, sdkInt: 36
        ))
        #expect(AndroidDoctorProbe.warmHelperFact(status(.starting), milliseconds: 2) == .unavailable("the warm helper is starting"))
    }

    @Test("input whose command has gone is never sent")
    func goneInputIsDropped() async throws {
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

    @Test("input queued behind another command's slow request is dropped unsent once its command has gone, so a late tap never lands")
    func queuedInputOfGoneCommandIsDropped() async throws {
        let device = FakeHelperDevice()
        device.answer = { _, op, _ in op == "dump" ? .okAfter(FakeHelperDevice.tapTestDump, .milliseconds(800)) : nil }
        let fixture = BrokerFixture(device: device)
        try await fixture.start()
        let reader = try await HelperSession.attach(try fixture.client(), log: { _, _ in })
        let slow = Task { _ = try await reader.dump() }
        try await Task.sleep(for: .milliseconds(100))

        let stream = try #require(await HelperBrokerClient.open(fixture.socket))
        let inject = try HelperRequest.inject([], sync: true).adding(HelperBrokerWire.timeoutField, .int(5000)).payload(id: 7)
        try await stream.write(try HelperWire.frame(inject), deadline: .now + .seconds(2))
        try await Task.sleep(for: .milliseconds(200))
        await stream.close()
        try await slow.value
        try await Task.sleep(for: .milliseconds(200))

        #expect(!fixture.device.ops.contains("inject"))
        await reader.close()
        try await fixture.stop()
    }

    @Test("a request still queued when its command's timeout passes is refused unsent, and the helper keeps serving")
    func lateRequestIsRefusedUnsent() async throws {
        let device = FakeHelperDevice()
        device.answer = { _, op, _ in op == "dump" ? .okAfter(FakeHelperDevice.tapTestDump, .milliseconds(800)) : nil }
        let fixture = BrokerFixture(device: device)
        try await fixture.start()
        let reader = try await HelperSession.attach(try fixture.client(), log: { _, _ in })
        let slow = Task { _ = try await reader.dump() }
        try await Task.sleep(for: .milliseconds(100))

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

    @Test("a request's turn drops it when its command has gone or given up, and input that waited long enough to land late", arguments: [
        ("inject", true, Duration.milliseconds(10), Duration.seconds(5), HelperBroker.Unsent.gone),
        ("inject", false, .seconds(3), .seconds(25), .late(waited: .seconds(3))),
        ("dump", false, .seconds(16), .seconds(15), .late(waited: .seconds(16))),
        ("dump", true, .seconds(1), .seconds(15), nil),
        ("dump", false, .seconds(3), .seconds(15), nil),
        ("inject", false, .seconds(1), .seconds(5), nil),
    ] as [(String, Bool, Duration, Duration, HelperBroker.Unsent?)])
    func unsentRules(op: String, peerClosed: Bool, waited: Duration, timeout: Duration, expected: HelperBroker.Unsent?) {
        #expect(HelperBroker.unsent(op: op, peerClosed: peerClosed, waited: waited, timeout: timeout) == expected)
    }

    @Test("a broker with another idle timeout that serves another command is kept, so neither command cuts the other off")
    func otherIdleInUseIsKept() async throws {
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

    @Test("a broker of another build that serves another command is left running, and this command is told to start its own helper")
    func otherBuildInUseIsLeft() async throws {
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
