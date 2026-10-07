import Foundation
import OffsiderCore
@testable import OffsiderIOSDevice
import Testing

@Suite("iOS device runner session")
@MainActor
struct RunnerSessionTests {
    static let udid = IOSDeviceFixtures.phone

    static func record(
        pid: Int32 = 4242, buildKey: String = "key", version: String = RunnerClient.protocolVersion,
        process: RunnerProcessIdentity? = FakeRunnerProcesses.identity, state: RunnerSessionRecord.State = .running
    ) -> RunnerSessionRecord {
        RunnerSessionRecord(
            udid: udid, pid: pid, port: 31337, token: "old-token",
            startedAt: Date(timeIntervalSince1970: 1_800_000_000), lastUsed: Date(timeIntervalSince1970: 1_800_000_100),
            buildKey: buildKey, version: version, transport: .usbmux, process: process, state: state
        )
    }

    static func manager(
        root: String, processes: FakeRunnerProcesses, transport: FakeRunnerTransport, builder: FakeRunnerBuilder = FakeRunnerBuilder(),
        environment: [String: String] = [:], now: @escaping @Sendable () -> Date = { Date() }, startTimeout: TimeInterval = 150, lockTimeout: TimeInterval = 180,
        usbmux: any UsbmuxListing = FakeUsbmuxListing.onUSB(udid), usbmuxCheckInterval: TimeInterval = 2, usbmuxGrace: TimeInterval = 10
    ) -> RunnerSessionManager {
        RunnerSessionManager(
            store: RunnerSessionStore(root: root), builder: builder, processes: processes, environment: environment,
            developerDirectory: "/Xcode.app/Contents/Developer", transport: { _, _ in transport }, log: { _, _ in }, now: now,
            startTimeout: startTimeout, lockTimeout: lockTimeout, usbmux: usbmux, usbmuxCheckInterval: usbmuxCheckInterval, usbmuxGrace: usbmuxGrace
        )
    }

    /// A usbmuxd whose every read takes one second of `clock`, so a busy machine cannot stretch a drop past the grace period.
    static func ticking(_ script: [[UsbmuxDevice]], clock: FixtureClock, then last: (@Sendable () -> Void)? = nil) -> FakeUsbmuxListing {
        let usbmux = FakeUsbmuxListing(script: script)
        usbmux.onRead = { read in
            clock.now += 1
            if read == script.count { last?() }
        }
        return usbmux
    }

    /// The log path xcodebuild was launched with, once it has been, so a test acts on the starting runner instead of racing its launch.
    static func launchedLogPath(_ processes: FakeRunnerProcesses) async throws -> String {
        for _ in 0..<200 where processes.launches.isEmpty {
            try await Task.sleep(for: .milliseconds(50))
        }
        return try #require(processes.launches.first?.logPath)
    }

    @Test("the session file round-trips, is private, and lists only devices with a session")
    func roundTrip() throws {
        let root = RunnerTestPaths.temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let store = RunnerSessionStore(root: root)
        #expect(try store.read(udid: Self.udid) == nil)
        try store.write(Self.record())

        #expect(try store.read(udid: Self.udid) == Self.record())
        #expect(store.all() == [Self.record()])
        let file = "\(root)/ios-devices/\(Self.udid)/runner.json"
        #expect(try FileManager.default.attributesOfItem(atPath: file)[.posixPermissions] as? Int == 0o600)
        store.remove(udid: Self.udid)
        #expect(store.all().isEmpty)
    }

    @Test("a live session with this build is reused without starting xcodebuild")
    func reuse() async throws {
        let root = RunnerTestPaths.temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try RunnerSessionStore(root: root).write(Self.record())
        let processes = FakeRunnerProcesses(alive: [4242])
        let transport = FakeRunnerTransport(buildKey: "key")
        let usbmux = FakeUsbmuxListing.onUSB(Self.udid)

        let client = try await Self.manager(root: root, processes: processes, transport: transport, usbmux: usbmux).connect(.device(udid: Self.udid), deviceName: "iPhone")

        #expect(client.token == "old-token")
        #expect(processes.launches.isEmpty)
        #expect(transport.calls.map(\.path) == ["/ping"])
        #expect(usbmux.reads == 0)
    }

    @Test("a session from another build or a dead process is stopped and replaced", arguments: [(true, "older-key"), (false, "key")])
    func stale(alive: Bool, recordedKey: String) async throws {
        let root = RunnerTestPaths.temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try RunnerSessionStore(root: root).write(Self.record(buildKey: recordedKey))
        let processes = FakeRunnerProcesses(alive: alive ? [4242] : [])
        let transport = FakeRunnerTransport(buildKey: "key")

        let client = try await Self.manager(root: root, processes: processes, transport: transport, environment: ["OFFSIDER_IOS_RUNNER_IDLE": "45"])
            .connect(.device(udid: Self.udid), deviceName: "iPhone")

        #expect(processes.launches.count == 1)
        #expect(processes.terminations == (alive ? [4242] : []))
        let launch = try #require(processes.launches.first)
        #expect(launch.arguments.starts(with: ["test-without-building", "-xctestrun", "/cache/key/Runner.xctestrun", "-destination", "id=\(Self.udid)", "-resultBundlePath"]))
        #expect(launch.environment["TEST_RUNNER_OFFSIDER_RUNNER_IDLE_SECONDS"] == "45")
        #expect(launch.environment["TEST_RUNNER_OFFSIDER_RUNNER_BUILD_KEY"] == "key")
        #expect(launch.environment["DEVELOPER_DIR"] == "/Xcode.app/Contents/Developer")
        let token = try #require(launch.environment["TEST_RUNNER_OFFSIDER_RUNNER_TOKEN"])
        #expect(token.count == 64 && token.allSatisfy(\.isHexDigit) && token == client.token)
        let saved = try #require(try RunnerSessionStore(root: root).read(udid: Self.udid))
        #expect(saved.pid == 5151 && saved.token == token && saved.buildKey == "key")
        #expect(String(saved.port) == launch.environment["TEST_RUNNER_OFFSIDER_RUNNER_PORT"])
        #expect(transport.calls.last?.token == token)
    }

    @Test("a runner whose xcodebuild exits before answering fails at once with runner_unavailable, saying so with the log's tail, and leaves no session")
    func startFails() async throws {
        let root = RunnerTestPaths.temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let processes = FakeRunnerProcesses(launchLog: Data("xcodebuild: error: The test runner failed to launch.\n".utf8))
        let transport = FakeRunnerTransport()
        transport.refuseConnections = true
        let manager = Self.manager(root: root, processes: processes, transport: transport, startTimeout: 20)

        let launching = Task { try await manager.connect(.device(udid: Self.udid), deviceName: "iPhone") }
        _ = try await Self.launchedLogPath(processes)
        try await Task.sleep(for: .milliseconds(300))
        processes.exit(5151)
        let error = await #expect(throws: IOSDeviceError.self) { _ = try await launching.value }
        #expect(error?.reason == .runnerUnavailable)
        #expect(error?.message.hasPrefix("xcodebuild exited before the Offsider runner on \(Self.udid) answered.") == true)
        #expect(error?.message.hasSuffix("\nxcodebuild: error: The test runner failed to launch.") == true)
        #expect(error?.hint?.hasSuffix("runner.log") == true)
        #expect(try RunnerSessionStore(root: root).read(udid: Self.udid) == nil)
    }

    @Test("a live xcodebuild whose runner never answers, with no unlock prompt in its log, fails at the start timeout with runner_unavailable")
    func startTimesOut() async throws {
        let root = RunnerTestPaths.temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let processes = FakeRunnerProcesses(launchLog: Data("Testing started\n".utf8))
        let transport = FakeRunnerTransport()
        transport.refuseConnections = true
        let manager = Self.manager(root: root, processes: processes, transport: transport, startTimeout: 1)

        let error = await #expect(throws: IOSDeviceError.self) { _ = try await manager.connect(.device(udid: Self.udid), deviceName: "iPad") }

        #expect(error?.reason == .runnerUnavailable)
        #expect(error?.message.hasPrefix("The Offsider runner on \(Self.udid) did not start within 1 seconds. Unlock the device") == true)
        #expect(processes.terminations == [5151])
    }

    @Test("a start whose xcodebuild waits for the device to be unlocked fails at once with device_locked, ends xcodebuild and leaves no session")
    func lockedDeviceFailsFast() async throws {
        let root = RunnerTestPaths.temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let fixture = try IOSDeviceFixtures.text("xcodebuild-runner-locked.log")
        let prompt = try #require(fixture.range(of: "Error Domain="))
        let processes = FakeRunnerProcesses(launchLog: Data(fixture[..<prompt.lowerBound].utf8))
        let transport = FakeRunnerTransport()
        transport.refuseConnections = true
        let manager = Self.manager(root: root, processes: processes, transport: transport, startTimeout: 20)
        let name = "iPad (\(Self.udid))"

        let launching = Task { try await manager.connect(.device(udid: Self.udid), deviceName: name) }
        let path = try await Self.launchedLogPath(processes)
        try await Task.sleep(for: .milliseconds(300))
        let log = try #require(FileHandle(forWritingAtPath: path))
        try log.seekToEnd()
        try log.write(contentsOf: Data(fixture[prompt.lowerBound...].utf8))
        try log.close()
        let error = await #expect(throws: IOSDeviceError.self) { _ = try await launching.value }

        #expect(error?.reason == .deviceLocked && error?.reason.exitCode == .deviceUnavailable)
        #expect(error?.message == "\(name) is locked, so Xcode cannot start the Offsider runner. Unlock it, then retry; Offsider never types a passcode.")
        #expect(processes.terminations == [5151])
        #expect(try RunnerSessionStore(root: root).read(udid: Self.udid) == nil)
    }

    @Test("an xcodebuild that exits right after asking for the device to be unlocked is device_locked, not runner_unavailable")
    func lockedThenExited() async throws {
        let root = RunnerTestPaths.temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let processes = FakeRunnerProcesses(launchLog: try IOSDeviceFixtures.data("xcodebuild-runner-locked.log"), exitsOnLaunch: true)
        let transport = FakeRunnerTransport()
        transport.refuseConnections = true
        let manager = Self.manager(root: root, processes: processes, transport: transport, startTimeout: 20)

        let error = await #expect(throws: IOSDeviceError.self) { _ = try await manager.connect(.device(udid: Self.udid), deviceName: "iPad") }

        #expect(error?.reason == .deviceLocked)
        #expect(try RunnerSessionStore(root: root).read(udid: Self.udid) == nil)
    }

    @Test("an xcodebuild that exits after XCTest timed out enabling automation is ui_automation_off naming the passcode prompt, not runner_unavailable")
    func automationTimeoutThenExited() async throws {
        let root = RunnerTestPaths.temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let processes = FakeRunnerProcesses(launchLog: try IOSDeviceFixtures.data("xcodebuild-runner-automation-timeout.log"), exitsOnLaunch: true)
        let transport = FakeRunnerTransport()
        transport.refuseConnections = true
        let manager = Self.manager(root: root, processes: processes, transport: transport, startTimeout: 20)

        let error = await #expect(throws: IOSDeviceError.self) { _ = try await manager.connect(.device(udid: Self.udid), deviceName: "iPad") }

        #expect(error?.reason == .uiAutomationOff)
        #expect(error?.message.contains(#"Enter Passcode for "XCTest""#) == true)
        #expect(try RunnerSessionStore(root: root).read(udid: Self.udid) == nil)
    }

    @Test("stop asks the runner to stop, then signals a process that lingers and removes the session")
    func stop() async throws {
        let root = RunnerTestPaths.temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let store = RunnerSessionStore(root: root)
        try store.write(Self.record())
        let processes = FakeRunnerProcesses(alive: [4242])
        let transport = FakeRunnerTransport()
        let record = Self.record()

        await Self.manager(root: root, processes: processes, transport: transport).stop(record)

        #expect(processes.terminations == [4242])
        #expect(try store.read(udid: Self.udid) == nil)
    }

    @Test("a recorded pid now running another process is forgotten and never signalled", arguments: [
        FakeRunnerProcesses.identity.startTime + 1,
        FakeRunnerProcesses.identity.startTime,
    ])
    func recycledPID(liveStart: UInt64) async throws {
        let root = RunnerTestPaths.temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let store = RunnerSessionStore(root: root)
        // The second case is a record from before identities were kept: the pid lives, but nothing proves it is the runner.
        let recorded = liveStart == FakeRunnerProcesses.identity.startTime ? Self.record(process: nil) : Self.record()
        try store.write(recorded)
        let processes = FakeRunnerProcesses(alive: [4242], startTimes: [4242: liveStart])
        let manager = Self.manager(root: root, processes: processes, transport: FakeRunnerTransport())

        await manager.stop(recorded)
        #expect(try store.read(udid: Self.udid) == nil)

        try store.write(recorded)
        _ = try await manager.connect(.device(udid: Self.udid), deviceName: "iPhone")

        #expect(processes.terminations.isEmpty)
        #expect(processes.launches.count == 1)
        #expect(try store.read(udid: Self.udid)?.pid == 5151)
    }

    @Test("a runner that accepts the connection but is slow to answer is busy, so it is reused and never stopped")
    func busyRunnerReused() async throws {
        let root = RunnerTestPaths.temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try RunnerSessionStore(root: root).write(Self.record())
        let processes = FakeRunnerProcesses(alive: [4242])
        let transport = FakeRunnerTransport()
        transport.pingTimesOut = true

        let client = try await Self.manager(root: root, processes: processes, transport: transport).connect(.device(udid: Self.udid), deviceName: "iPhone")

        #expect(client.token == "old-token")
        #expect(processes.launches.isEmpty && processes.terminations.isEmpty)
        #expect(!transport.calls.contains { $0.path == "/stop" })
    }

    @Test("a live runner that refuses the connection is stopped and replaced")
    func refusedRunnerRestarted() async throws {
        let root = RunnerTestPaths.temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        var recorded = Self.record()
        recorded.port = 1
        try RunnerSessionStore(root: root).write(recorded)
        let processes = FakeRunnerProcesses(alive: [4242])
        let refusing = FakeRunnerTransport()
        refusing.refuseConnections = true
        let fresh = FakeRunnerTransport()
        let manager = RunnerSessionManager(
            store: RunnerSessionStore(root: root), builder: FakeRunnerBuilder(), processes: processes, environment: [:],
            developerDirectory: nil, transport: { _, port in port == 1 ? refusing : fresh }, log: { _, _ in }, usbmux: FakeUsbmuxListing.onUSB(Self.udid)
        )

        let client = try await manager.connect(.device(udid: Self.udid), deviceName: "iPhone")

        #expect(processes.terminations == [4242])
        #expect(processes.launches.count == 1)
        #expect(client.token != "old-token")
    }

    @Test("a device usbmuxd lists without a USB row, or a usbmuxd that is not answering, fails at once before xcodebuild starts", arguments: ["empty", "network", "no socket"])
    func notOnUsbmuxBeforeStart(listing: String) async throws {
        let root = RunnerTestPaths.temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let rows: [(id: Int, udid: String, type: String)] = listing == "network" ? [(9, Self.udid, "Network")] : []
        let usbmuxd = try FakeUsbmuxd(reply: UsbmuxTests.standard(rows: rows))
        defer { usbmuxd.stop() }
        let socket = listing == "no socket" ? usbmuxd.path + ".missing" : usbmuxd.path
        let processes = FakeRunnerProcesses()
        let manager = Self.manager(root: root, processes: processes, transport: FakeRunnerTransport(), usbmux: UsbmuxClient(socketPath: socket, timeout: 1))

        let error = await #expect(throws: IOSDeviceError.self) { _ = try await manager.connect(.device(udid: Self.udid), deviceName: "iPad (\(Self.udid))") }

        #expect(error?.reason == .usbmuxUnavailable && error?.reason.exitCode == .toolMissing)
        if listing != "no socket" {
            #expect(error?.message == "usbmuxd does not list iPad (\(Self.udid)) on USB, so Offsider cannot reach its runner. Unplug and replug the cable, then retry.")
        }
        #expect(processes.launches.isEmpty)
    }

    @Test("a recorded runner usbmuxd no longer lists fails at once with usbmux_unavailable and is kept, never restarted")
    func recordedRunnerOffUsbmux() async throws {
        let root = RunnerTestPaths.temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try RunnerSessionStore(root: root).write(Self.record())
        let processes = FakeRunnerProcesses(alive: [4242])
        let transport = FakeRunnerTransport()
        transport.refuseConnections = true
        let manager = Self.manager(root: root, processes: processes, transport: transport, startTimeout: 5, usbmux: FakeUsbmuxListing([]))

        let error = await #expect(throws: IOSDeviceError.self) { _ = try await manager.connect(.device(udid: Self.udid), deviceName: "iPad") }

        #expect(error?.reason == .usbmuxUnavailable)
        #expect(processes.launches.isEmpty && processes.terminations.isEmpty)
        #expect(try RunnerSessionStore(root: root).read(udid: Self.udid) == Self.record())
    }

    @Test("a starting runner whose device usbmuxd stops listing fails once it has been missing for the grace period, not at the start timeout")
    func droppedWhileStarting() async throws {
        let root = RunnerTestPaths.temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let processes = FakeRunnerProcesses()
        let transport = FakeRunnerTransport()
        transport.refuseConnections = true
        let clock = FixtureClock()
        let listed = [UsbmuxDevice(deviceID: 3, udid: Self.udid, connectionType: "USB")]
        let usbmux = Self.ticking([listed] + Array(repeating: [], count: 10), clock: clock)
        let manager = Self.manager(
            root: root, processes: processes, transport: transport, now: { clock.now }, startTimeout: 120, usbmux: usbmux, usbmuxCheckInterval: 0, usbmuxGrace: 3
        )

        let error = await #expect(throws: IOSDeviceError.self) { _ = try await manager.connect(.device(udid: Self.udid), deviceName: "iPad") }

        #expect(error?.reason == .usbmuxUnavailable)
        // One read before the launch; missing for 0, 1 and 2 s goes on, and for 3 s fails.
        #expect(usbmux.reads == 5)
        #expect(processes.terminations == [5151])
        #expect(try RunnerSessionStore(root: root).read(udid: Self.udid) == nil)
    }

    @Test("drops from usbmuxd each shorter than the grace period do not fail a starting runner")
    func briefDropsTolerated() async throws {
        let root = RunnerTestPaths.temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let processes = FakeRunnerProcesses()
        let transport = FakeRunnerTransport()
        transport.refuseConnections = true
        let clock = FixtureClock()
        let listed = [UsbmuxDevice(deviceID: 3, udid: Self.udid, connectionType: "USB")]
        let usbmux = Self.ticking([listed, [], [], [], listed, [], [], [], listed], clock: clock) { transport.refuseConnections = false }
        let manager = Self.manager(
            root: root, processes: processes, transport: transport, now: { clock.now }, startTimeout: 120, usbmux: usbmux, usbmuxCheckInterval: 0, usbmuxGrace: 3
        )

        _ = try await manager.connect(.device(udid: Self.udid), deviceName: "iPad")

        #expect(processes.terminations.isEmpty)
        #expect(usbmux.reads == 9)
    }

    @Test("a simulator's runner starts without asking usbmuxd")
    func simulatorSkipsUsbmux() async throws {
        let root = RunnerTestPaths.temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let processes = FakeRunnerProcesses()
        let usbmux = FakeUsbmuxListing([])

        _ = try await Self.manager(root: root, processes: processes, transport: FakeRunnerTransport(), usbmux: usbmux).connect(.simulator(udid: Self.udid), deviceName: "iPhone 17")

        #expect(processes.launches.count == 1)
        #expect(usbmux.reads == 0)
    }

    @Test("the session is recorded as starting as soon as xcodebuild is spawned, before the runner answers")
    func recordedWhileStarting() async throws {
        let root = RunnerTestPaths.temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let store = RunnerSessionStore(root: root)
        let processes = FakeRunnerProcesses()
        let transport = FakeRunnerTransport()
        transport.refuseConnections = true
        let manager = Self.manager(root: root, processes: processes, transport: transport)

        let launching = Task { try await manager.connect(.device(udid: Self.udid), deviceName: "iPhone") }
        var recorded: RunnerSessionRecord?
        for _ in 0..<100 where recorded == nil {
            try await Task.sleep(for: .milliseconds(50))
            recorded = try store.read(udid: Self.udid)
        }
        let starting = try #require(recorded)
        #expect(starting.pid == 5151 && starting.state == .starting && starting.process == FakeRunnerProcesses.identity)

        transport.refuseConnections = false
        _ = try await launching.value
        #expect(try store.read(udid: Self.udid)?.state == .running)
    }

    @Test("a start an interrupted command left behind is adopted when it answers, and runner stop ends it otherwise")
    func interruptedStart() async throws {
        let root = RunnerTestPaths.temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let store = RunnerSessionStore(root: root)
        try store.write(Self.record(state: .starting))
        let processes = FakeRunnerProcesses(alive: [4242])
        let manager = Self.manager(root: root, processes: processes, transport: FakeRunnerTransport())

        let client = try await manager.connect(.device(udid: Self.udid), deviceName: "iPhone")
        #expect(client.token == "old-token" && processes.launches.isEmpty)
        #expect(try store.read(udid: Self.udid)?.state == .running)

        try store.write(Self.record(state: .starting))
        await manager.stop(Self.record(state: .starting))
        #expect(processes.terminations == [4242])
        #expect(try store.read(udid: Self.udid) == nil)
    }

    @Test("a held start lock is waited for even when its owner line names an exited process, and is free once released")
    func startLockHeld() async throws {
        let root = RunnerTestPaths.temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let manager = Self.manager(root: root, processes: FakeRunnerProcesses(), transport: FakeRunnerTransport(), lockTimeout: 0.5)
        let held = try await manager.acquireStartLock(udid: Self.udid)
        #expect(try String(contentsOfFile: held.path, encoding: .utf8) == IOSDeviceStartLock.owner(getpid()))
        try StartLockTests.claimForExitedProcess(held.path)

        let error = await #expect(throws: IOSDeviceError.self) { _ = try await manager.acquireStartLock(udid: Self.udid) }
        #expect(error?.reason == .runnerUnavailable)
        #expect(error?.message.contains("still starting the runner") == true)

        held.release()
        let patient = Self.manager(root: root, processes: FakeRunnerProcesses(), transport: FakeRunnerTransport(), lockTimeout: TestDevices.releaseGrace)
        let next = try await patient.acquireStartLock(udid: Self.udid)
        #expect(try String(contentsOfFile: next.path, encoding: .utf8) == IOSDeviceStartLock.owner(getpid()))
        next.release()
    }
}

@Suite("iOS device runner builder")
struct RunnerBuilderTests {
    static func sourceDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("offsider-runner-src-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url.appendingPathComponent("UITests"), withIntermediateDirectories: true)
        try Data("name: OffsiderRunner\n".utf8).write(to: url.appendingPathComponent("project.yml"))
        try Data("final class RunnerTests {}\n".utf8).write(to: url.appendingPathComponent("UITests/RunnerTests.swift"))
        return url
    }

    @Test("the cache key is stable and changes with the source, Xcode build, team and destination")
    func keyStability() throws {
        let source = try Self.sourceDirectory()
        defer { try? FileManager.default.removeItem(at: source) }
        let digest = try XcodeRunnerBuilder.sourceDigest(of: source)
        let key = XcodeRunnerBuilder.key(sourceDigest: digest, xcodeBuild: "27A266a", team: "ABCDE12345", destination: .device(udid: "U"))
        #expect(key == XcodeRunnerBuilder.key(sourceDigest: try XcodeRunnerBuilder.sourceDigest(of: source), xcodeBuild: "27A266a", team: "ABCDE12345", destination: .device(udid: "U")))
        #expect(key.count == 64)

        try FileManager.default.createDirectory(at: source.appendingPathComponent("x.xcodeproj/xcuserdata"), withIntermediateDirectories: true)
        try Data("state".utf8).write(to: source.appendingPathComponent("x.xcodeproj/xcuserdata/me.plist"))
        #expect(try XcodeRunnerBuilder.sourceDigest(of: source) == digest)

        try Data("final class RunnerTests { }\n".utf8).write(to: source.appendingPathComponent("UITests/RunnerTests.swift"))
        let changed = try XcodeRunnerBuilder.sourceDigest(of: source)
        #expect(changed != digest)
        let others = [
            XcodeRunnerBuilder.key(sourceDigest: digest, xcodeBuild: "27B5", team: "ABCDE12345", destination: .device(udid: "U")),
            XcodeRunnerBuilder.key(sourceDigest: digest, xcodeBuild: "27A266a", team: "ZZZZZ99999", destination: .device(udid: "U")),
            XcodeRunnerBuilder.key(sourceDigest: digest, xcodeBuild: "27A266a", team: nil, destination: .simulator(udid: "U")),
        ]
        #expect(Set(others + [key]).count == 4)
    }

    @Test("the team comes from OFFSIDER_IOS_TEAM_ID first, then Xcode's only signed-in team")
    func teamResolution() throws {
        #expect(try XcodeRunnerBuilder.resolveTeam(environment: ["OFFSIDER_IOS_TEAM_ID": "ABCDE12345"], signedInTeams: ["Q1", "Q2"]) == "ABCDE12345")
        #expect(try XcodeRunnerBuilder.resolveTeam(environment: [:], signedInTeams: ["TEAM000001"]) == "TEAM000001")
    }

    @Test("no team, several teams or a malformed variable is team_missing naming the variable", arguments: [
        ([String: String](), [String]()),
        ([:], ["AAAAA11111", "BBBBB22222"]),
        (["OFFSIDER_IOS_TEAM_ID": "not a team"], ["AAAAA11111"]),
    ])
    func teamMissing(environment: [String: String], teams: [String]) {
        let error = #expect(throws: IOSDeviceError.self) {
            _ = try XcodeRunnerBuilder.resolveTeam(environment: environment, signedInTeams: teams)
        }
        #expect(error?.reason == .teamMissing)
        #expect(error?.reason.exitCode == .toolMissing)
        #expect(error?.message.contains("OFFSIDER_IOS_TEAM_ID") == true)
    }

    @Test("a cached build is returned without running xcodebuild")
    func cacheHit() async throws {
        let source = try Self.sourceDirectory()
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent("offsider-runner-cache-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: cache)
        }
        let xcode = XcodeLocation(developerDirectory: "/nonexistent/Developer", source: "test", version: "27.0", build: "27A266a")
        let key = XcodeRunnerBuilder.key(sourceDigest: try XcodeRunnerBuilder.sourceDigest(of: source), xcodeBuild: "27A266a", team: "ABCDE12345", destination: .device(udid: "U"))
        let products = cache.appendingPathComponent("\(key)/derived/Build/Products")
        try FileManager.default.createDirectory(at: products, withIntermediateDirectories: true)
        try Data().write(to: products.appendingPathComponent("OffsiderRunner_iphoneos27.0-arm64.xctestrun"))
        let notices = LineSink()
        let builder = XcodeRunnerBuilder(
            source: source, cacheRoot: cache, xcode: xcode, environment: ["OFFSIDER_IOS_TEAM_ID": "ABCDE12345"],
            signedInTeams: { [] }, notice: notices.append
        )

        let build = try await builder.build(for: .device(udid: "U"), deviceName: "iPhone")

        #expect(build.key == key)
        #expect(build.xctestrun.lastPathComponent == "OffsiderRunner_iphoneos27.0-arm64.xctestrun")
        #expect(notices.values.isEmpty)
    }

    @Test("a phone build without a team fails before xcodebuild runs")
    func buildNeedsTeam() async throws {
        let source = try Self.sourceDirectory()
        defer { try? FileManager.default.removeItem(at: source) }
        let notices = LineSink()
        let builder = XcodeRunnerBuilder(
            source: source, cacheRoot: URL(fileURLWithPath: "/nonexistent"), xcode: XcodeLocation(developerDirectory: "/x", source: "t", version: "27.0", build: "27A"),
            environment: [:], signedInTeams: { ["AAAAA11111", "BBBBB22222"] }, notice: notices.append
        )
        let error = await #expect(throws: IOSDeviceError.self) { _ = try await builder.build(for: .device(udid: "U"), deviceName: "iPhone") }
        #expect(error?.reason == .teamMissing)
        #expect(notices.values.isEmpty)
    }

    @Test("a cache folder Offsider cannot write is runner_build_failed, not a raw Foundation error")
    func cacheFailureMapped() async throws {
        let source = try Self.sourceDirectory()
        let blocker = FileManager.default.temporaryDirectory.appendingPathComponent("offsider-runner-file-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: blocker)
        }
        try Data("not a folder".utf8).write(to: blocker)
        let builder = XcodeRunnerBuilder(
            source: source, cacheRoot: blocker.appendingPathComponent("runner"), xcode: XcodeLocation(developerDirectory: "/x", source: "t", version: "27.0", build: "27A"),
            environment: ["OFFSIDER_IOS_TEAM_ID": "ABCDE12345"], signedInTeams: { [] }, notice: { _ in }
        )
        let error = await #expect(throws: IOSDeviceError.self) { _ = try await builder.build(for: .device(udid: "U"), deviceName: "iPhone") }
        #expect(error?.reason == .runnerBuildFailed)
        #expect(error?.message.contains(blocker.path) == true)
    }

    @Test("two builds of one key never run at once")
    func buildLockSerialises() async throws {
        let lock = FileManager.default.temporaryDirectory.appendingPathComponent("offsider-runner-\(UUID().uuidString).lock")
        defer { try? FileManager.default.removeItem(at: lock) }
        let tracker = OverlapTracker()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<2 {
                group.addTask {
                    try await XcodeRunnerBuilder.withBuildLock(lock) {
                        tracker.enter()
                        try await Task.sleep(for: .milliseconds(300))
                        tracker.leave()
                    }
                }
            }
            try await group.waitForAll()
        }
        #expect(tracker.entries == 2 && tracker.peak == 1)
    }

    @Test("a failed build is runner_build_failed with the log's last lines and its path as the hint")
    func buildFailure() {
        let output = (1...30).map { "line \($0)" }.joined(separator: "\n")
        let error = XcodeRunnerBuilder.failure(detail: "xcodebuild exited 65", output: output, log: URL(fileURLWithPath: "/cache/k/build.log"))
        #expect(error.reason == .runnerBuildFailed)
        #expect(error.message.contains("line 30") && error.message.contains("line 11") && !error.message.contains("line 10\n"))
        #expect(error.hint == "See /cache/k/build.log")
    }
}

@Suite("iOS device runner client and backend")
@MainActor
struct RunnerClientTests {
    static let phone = DeviceID(rawValue: IOSDeviceFixtures.phone, platform: .ios)

    static func backend(_ transport: FakeRunnerTransport) throws -> (IOSDeviceBackend, FakeRunnerConnector) {
        let connector = FakeRunnerConnector(transport: transport)
        var host = IOSDeviceHost.fake(try FakeDevicectl.listing("devicectl-list-xcode26.json"))
        host.runnerConnector = connector
        // An Xcode 26 host, so input reaches the runner rather than CoreDevice HID.
        let backend = IOSDeviceBackend(host: host) { _, _ in }
        backend.input.coreDeviceVersion = { CoreDeviceVersion("518.24") }
        return (backend, connector)
    }

    @Test("the client sends the session token, and a runner that refuses it is runner_unavailable")
    func tokenRequired() async throws {
        let server = try FakeRunnerHTTPServer(token: "right") { _ in
            (200, Data(#"{"ok":true,"data":{"version":"1","buildKey":"k","screenBounds":{"width":430,"height":932},"scale":3,"orientation":"portrait","activeBundleId":"com.example"}}"#.utf8))
        }
        defer { server.stop() }

        let ping = try await RunnerClient(udid: "U", token: "right", transport: LoopbackRunnerTransport(port: server.port)).ping()
        #expect(ping == RunnerPing(version: "1", buildKey: "k", screenWidth: 430, screenHeight: 932, scale: 3, orientation: "portrait", activeBundleID: "com.example"))

        let error = await #expect(throws: IOSDeviceError.self) {
            _ = try await RunnerClient(udid: "U", token: "wrong", transport: LoopbackRunnerTransport(port: server.port)).ping()
        }
        #expect(error?.reason == .runnerUnavailable)
        #expect(error?.hint == "offsider runner stop --device U")
    }

    @Test("nothing listening is runner_unavailable, and a runner error envelope is a tree read failure")
    func failures() async throws {
        let refused = await #expect(throws: IOSDeviceError.self) {
            _ = try await RunnerClient(udid: "U", token: "t", transport: LoopbackRunnerTransport(port: 1)).ping(timeout: 0.5)
        }
        #expect(refused?.reason == .runnerUnavailable)

        let transport = FakeRunnerTransport()
        transport.failure = ("/snapshot", 409, "snapshot_failed")
        let failed = await #expect(throws: IOSDeviceError.self) {
            _ = try await RunnerClient(udid: "U", token: "t", transport: transport).snapshot(app: nil)
        }
        #expect(failed?.reason == .treeReadFailed)
    }

    @Test("the runner snapshot maps through the iOS mapper with roles, ids, state and a masked secure value")
    func snapshotMapping() async throws {
        let transport = FakeRunnerTransport(snapshot: try IOSDeviceFixtures.data("runner-snapshot.json"))
        let (backend, _) = try Self.backend(transport)
        backend.targetApp = "com.mpalmes.offsider.playground"

        let tree = try await backend.accessibilityTree(for: Self.phone, point: nil)

        #expect(tree.platform == .ios && tree.device == IOSDeviceFixtures.phone)
        let root = try #require(tree.roots.first)
        #expect(root.role == .application)
        if case .ios(let native) = root.native { #expect(native.pid == 87579) } else { Issue.record("not iOS attributes") }
        let window = try #require(root.children.first)
        #expect(window.children.map(\.role) == [.header, .button, .switch, .secureTextField])
        #expect(window.children[1].label == "Tap Test, Displays coordinates of CLI taps")
        #expect(window.children[2].id == "wifi-switch" && window.children[2].state.checked == true)
        #expect(window.children[3].value != "hunter2")
        #expect(window.children.map(\.state.focused) == [nil, nil, nil, true])
        #expect(tree.secureFocus == .secureFocused)
        #expect(transport.calls.last?.body["app"] == AnyHashable("com.mpalmes.offsider.playground"))
    }

    @Test("a snapshot the runner cut short reads as truncated, and a complete one does not")
    func truncatedSnapshot() async throws {
        let complete = try IOSDeviceFixtures.data("runner-snapshot.json")
        var roots = try #require(try JSONSerialization.jsonObject(with: complete) as? [[String: Any]])
        roots[0]["truncated"] = true
        let truncated = try JSONSerialization.data(withJSONObject: roots)

        let (whole, _) = try Self.backend(FakeRunnerTransport(snapshot: complete))
        #expect(try await whole.accessibilityTree(for: Self.phone, point: nil).sourceTruncated == false)
        let (cut, _) = try Self.backend(FakeRunnerTransport(snapshot: truncated))
        let tree = try await cut.accessibilityTree(for: Self.phone, point: nil)
        #expect(tree.sourceTruncated)
        #expect(tree.roots.first?.children.isEmpty == false)
    }

    @Test("a point keeps only the deepest node there")
    func pointFilter() async throws {
        let (backend, _) = try Self.backend(FakeRunnerTransport(snapshot: try IOSDeviceFixtures.data("runner-snapshot.json")))
        let tree = try await backend.accessibilityTree(for: Self.phone, point: UIPoint(x: 40, y: 230))
        #expect(tree.roots.map(\.label) == ["Tap Test"])
        let outside = try await backend.accessibilityTree(for: Self.phone, point: UIPoint(x: 5000, y: 5000))
        #expect(outside.roots.isEmpty)
    }

    @Test("one runner connection serves a whole command")
    func oneConnection() async throws {
        let (backend, connector) = try Self.backend(FakeRunnerTransport())
        _ = try await backend.rawAccessibilitySource(for: Self.phone)
        _ = try await backend.openInputSession(for: Self.phone)
        #expect(connector.connections == 1)
    }

    @Test("taps, swipes, Home and text the keyboard cannot send go through the runner")
    func runnerInput() async throws {
        let transport = FakeRunnerTransport()
        let (backend, _) = try Self.backend(transport)
        backend.targetApp = "com.example.app"
        let session = try await backend.openInputSession(for: Self.phone)
        try await session.perform(.tapAt(x: 10, y: 20))
        try await session.performPhysicalTap(at: (x: 30, y: 40), preDelay: nil, postDelay: nil)
        try await session.perform(.swipe(1, yStart: 2, xEnd: 3, yEnd: 4, delta: 10, duration: 0.5))
        try await session.perform(.shortButtonPress(.home))
        let text = try #require(session as? any TextInputSession)
        try await text.typeText("héllo")
        try await text.replaceText("new")

        #expect(transport.calls.map(\.path) == ["/tap-point", "/tap-point", "/swipe", "/home", "/type", "/type"])
        #expect(transport.calls[0].body == ["x": 10.0, "y": 20.0, "app": "com.example.app"])
        #expect(transport.calls[2].body["duration"] == AnyHashable(0.5))
        #expect(transport.calls[4].body["replace"] == AnyHashable(false) && transport.calls[5].body["replace"] == AnyHashable(true))
    }

    @Test("input the runner cannot send is xcode_too_old with the HID hint", arguments: [
        InputEvent.shortKeyPress(4),
        .touch(direction: .down, x: 1, y: 1),
        .shortButtonPress(.lock),
    ])
    func refusals(event: InputEvent) async throws {
        let transport = FakeRunnerTransport()
        let (backend, _) = try Self.backend(transport)
        let session = try await backend.openInputSession(for: Self.phone)
        let error = await #expect(throws: IOSDeviceError.self) { try await session.perform(event) }
        #expect(error?.reason == .xcodeTooOld)
        #expect(error?.hint == "install Xcode 27 for HID input")
        #expect(transport.calls.isEmpty)
    }

    @Test("plain ASCII typing is refused until HID input is available, and nothing is sent")
    func asciiRefused() async throws {
        let transport = FakeRunnerTransport()
        let (backend, _) = try Self.backend(transport)
        let session = try #require(try await backend.openInputSession(for: Self.phone) as? any TextInputSession)
        let error = await #expect(throws: IOSDeviceError.self) { try await session.typeText("hello") }
        #expect(error?.reason == .xcodeTooOld)
        #expect(transport.calls.isEmpty)
    }

    @Test("a secure field and a missing focus map to their own reasons", arguments: [("secure_field", FailureReason.securePasteRefused), ("no_focus", .noFocusedField)])
    func typeFailures(code: String, reason: FailureReason) async throws {
        let transport = FakeRunnerTransport()
        transport.failure = ("/type", 409, code)
        let error = await #expect(throws: IOSDeviceError.self) {
            try await RunnerClient(udid: "U", token: "t", transport: transport).type("x", replace: true, app: nil)
        }
        #expect(error?.reason == reason)
    }
}

/// Counts how many bodies run at once.
final class OverlapTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var current = 0
    private(set) var peak = 0
    private(set) var entries = 0

    func enter() {
        lock.withLock {
            current += 1
            entries += 1
            peak = max(peak, current)
        }
    }

    func leave() {
        lock.withLock { current -= 1 }
    }
}
