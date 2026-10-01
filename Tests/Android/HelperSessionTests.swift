import Foundation
import Testing
@testable import OffsiderAndroid

@Suite("Android helper session")
@MainActor
struct HelperSessionTests {
    static func start(_ device: FakeHelperDevice) async throws -> HelperSession {
        try await HelperSession.start(
            client: AdbClient(endpoint: .defaultAdbServer, connector: device.server()),
            serial: FakeHelperDevice.serial,
            dex: FakeHelperDevice.dex,
            log: { _, _ in }
        )
    }

    static func ids(_ device: FakeHelperDevice) -> [Int] {
        device.frames.compactMap { frame in
            frame.json.firstMatch(of: #/"id":(\d+)/#).flatMap { Int($0.1) }
        }
    }

    @Test("the first frame is hello with the ready line's token and protocol, and request ids increase")
    func helloFirst() async throws {
        let device = FakeHelperDevice()
        let session = try await Self.start(device)
        _ = try await session.dump()
        _ = try await session.dump()

        #expect(device.ops == ["hello", "dump", "dump"])
        #expect(device.frames.first?.json.contains(#""token":"token-1""#) == true)
        #expect(device.frames.first?.json.contains(#""protocol":1"#) == true)
        #expect(Self.ids(device) == [1, 2, 3])
        await session.close()
    }

    @Test("a dump keeps the display, the windows and the event cursor")
    func dumpState() async throws {
        let session = try await Self.start(FakeHelperDevice())
        let dump = try await session.dump()

        #expect(dump.windows.map(\.type) == ["system", "application"])
        #expect(session.display?.densityDpi == 420)
        #expect(session.windows == dump.windows)
        #expect(session.eventCursor == 3)
        #expect(session.ready.pid == 4001)
        await session.close()
    }

    @Test("an error reply to dump is an actionable error naming the device")
    func errorReply() async throws {
        let device = FakeHelperDevice()
        device.answer = { _, op, _ in op == "dump" ? .error(code: "dump-failed", message: "getWindows returned null") : nil }
        let session = try await Self.start(device)

        let error = await #expect(throws: AndroidError.self) { try await session.dump() }
        #expect(error?.kind == .helperFailed)
        #expect(error?.message == "The UiAutomation helper could not read the screen of emulator-5556 (getWindows returned null). Retry, or set OFFSIDER_ANDROID_TREE=uiautomator to read it another way.")
        await session.close()
    }

    @Test("a bye for idleness starts a new helper and resends, as often as it happens")
    func idleRestarts() async throws {
        let device = FakeHelperDevice()
        device.answer = { process, op, _ in op == "dump" && process < 3 ? .bye("idle") : nil }
        let session = try await Self.start(device)

        let dump = try await session.dump()

        #expect(dump.generation == 1)
        #expect(device.startedProcesses == 3)
        #expect(device.ops == ["hello", "dump", "hello", "dump", "hello", "dump"])
        #expect(session.ready.pid == 4003)
        await session.close()
    }

    @Test("a helper lost before its reply is started again once; a second loss is a crash")
    func lostTwice() async throws {
        let device = FakeHelperDevice()
        device.answer = { _, op, _ in op == "dump" ? .hangUp : nil }
        let session = try await Self.start(device)

        let error = await #expect(throws: AndroidError.self) { try await session.dump() }
        #expect(error?.kind == .helperCrashed)
        #expect(error?.message == "The UiAutomation helper on emulator-5556 stopped unexpectedly (its socket closed before it answered `dump`). Retry; `adb -s emulator-5556 logcat -d -s OffsiderHelper AndroidRuntime` shows why.")
        #expect(device.startedProcesses == 2)
        await session.close()
    }

    @Test("one loss, or a crash bye, costs only a restart")
    func lostOnce() async throws {
        let device = FakeHelperDevice()
        device.answer = { process, op, _ in op == "dump" && process == 1 ? .bye("crash") : nil }
        let session = try await Self.start(device)

        _ = try await session.dump()

        #expect(device.startedProcesses == 2)
        await session.close()
    }

    @Test("a missed deadline is a timeout naming the request, and the helper is told to quit")
    func deadline() async throws {
        let device = FakeHelperDevice()
        device.answer = { _, op, _ in op == "dump" ? .silence : nil }
        let session = try await Self.start(device)

        let error = await #expect(throws: AndroidError.self) { try await session.dump() }
        #expect(error?.message == "The UiAutomation helper on emulator-5556 did not answer `dump` within 15 s. The emulator may be overloaded; retry when it responds.")
        #expect(device.ops == ["hello", "dump", "quit"])
        await session.close()
        #expect(device.ops == ["hello", "dump", "quit"])
    }

    @Test("close() sends quit and waits for the exit, so the slot is free; a second close does nothing")
    func closes() async throws {
        let device = FakeHelperDevice()
        let session = try await Self.start(device)

        await session.close()
        await session.close()

        #expect(device.ops == ["hello", "quit"])
        let timeline = device.timeline
        let exited = try #require(timeline.firstIndex(of: "exit 1 0"))
        let closed = try #require(timeline.firstIndex(of: "shell closed 1"))
        #expect(exited < closed)
        #expect(device.kills.isEmpty)
    }

    @Test("a helper that does not exit after quit is killed by pid")
    func killsWithoutExit() async throws {
        let device = FakeHelperDevice()
        device.exitOnQuit = false
        let session = try await Self.start(device)

        await session.close()

        #expect(device.kills == [4001])
    }

    @Test("a hello reply with another protocol is a handshake failure, and both streams close")
    func helloProtocol() async {
        let device = FakeHelperDevice()
        device.answer = { _, op, _ in op == "hello" ? .ok(#"{"helper":"2.0.0","protocol":2}"#) : nil }

        await #expect(throws: HelperStartFailure.unavailable(.handshake("the helper on the device speaks protocol 2, Offsider speaks 1"))) {
            _ = try await Self.start(device)
        }
        #expect(device.timeline.contains("shell closed 1"))
        #expect(device.timeline.contains("socket closed 1"))
    }

    @Test("a refused socket is a handshake failure")
    func refusedSocket() async {
        let device = FakeHelperDevice()
        device.refuseSocket = true
        let error = await #expect(throws: HelperStartFailure.self) { _ = try await Self.start(device) }
        guard case .unavailable(.handshake) = error else {
            Issue.record("expected a handshake failure, got \(String(describing: error))")
            return
        }
        #expect(device.timeline.contains("shell closed 1"))
    }

    @Test("a helper that never answers hello is a handshake failure")
    func silentHello() async {
        let device = FakeHelperDevice()
        device.answer = { _, op, _ in op == "hello" ? .silence : nil }
        await #expect(throws: HelperStartFailure.unavailable(.handshake("no reply to hello within 2 s"))) {
            _ = try await Self.start(device)
        }
    }
}
