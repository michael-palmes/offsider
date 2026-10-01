import Foundation
import OffsiderCore
import Testing
@testable import OffsiderAndroid

@Suite("adb server launcher")
struct AdbServerLauncherTests {
    private static let adb = URL(fileURLWithPath: "/sdk/platform-tools/adb")

    @Test("a refused connection runs adb start-server once with mDNS off, then succeeds on retry")
    func startsServerWithoutMDNS() async throws {
        let server = FakeAdbServer(refusingFirst: 3) { _ in FakeAdbServer.okay(payload: "0029") }
        let processes = RecordingProcessRunner()
        let sleeps = SleepRecorder()
        let host = AndroidTestHost.make(environment: ["PATH": "/usr/bin", "ADB_MDNS": "1"], adb: server, processes: processes, sleeps: sleeps)

        try await AdbServerLauncher(adb: Self.adb).ensureRunning(client: AdbClient(endpoint: .defaultAdbServer, connector: server), host: host)

        #expect(processes.calls.count == 1)
        let call = try #require(processes.calls.first)
        #expect(call.executable == "/sdk/platform-tools/adb")
        #expect(call.arguments == ["start-server"])
        #expect(call.environment?["ADB_MDNS"] == "0")
        #expect(call.environment?["PATH"] == "/usr/bin")
        #expect(sleeps.sleeps == [.milliseconds(100), .milliseconds(100)])
    }

    @Test("a running server is never started, killed or restarted")
    func runningServerIsLeftAlone() async throws {
        let server = FakeAdbServer { _ in FakeAdbServer.okay(payload: "0029") }
        let processes = RecordingProcessRunner()
        let host = AndroidTestHost.make(adb: server, processes: processes)

        try await AdbServerLauncher(adb: Self.adb).ensureRunning(client: AdbClient(endpoint: .defaultAdbServer, connector: server), host: host)

        #expect(processes.calls.isEmpty)
        #expect(server.services == ["host:version"])
    }

    @Test("a failed start-server reports its status and first stderr line")
    func startFailure() async {
        let server = FakeAdbServer(connect: .refuse) { _ in .hang }
        let processes = RecordingProcessRunner { _ in ProcessCaptureResult(status: 1, stdout: "", stderr: "cannot bind 'tcp:5037'\nmore\n") }
        let host = AndroidTestHost.make(adb: server, processes: processes)

        let error = await #expect(throws: AndroidError.self) {
            try await AdbServerLauncher(adb: Self.adb).ensureRunning(client: AdbClient(endpoint: .defaultAdbServer, connector: server), host: host)
        }
        #expect(error?.message == "Could not start the adb server: `/sdk/platform-tools/adb start-server` exited 1 (cannot bind 'tcp:5037'). Run `adb start-server` to see why.")
    }

    @Test("a server that never comes up stops waiting after 5 s of retries")
    func neverComesUp() async {
        let server = FakeAdbServer(connect: .refuse) { _ in .hang }
        let sleeps = SleepRecorder()
        let host = AndroidTestHost.make(adb: server, sleeps: sleeps)

        let error = await #expect(throws: AndroidError.self) {
            try await AdbServerLauncher(adb: Self.adb).ensureRunning(client: AdbClient(endpoint: .defaultAdbServer, connector: server), host: host)
        }
        #expect(error?.kind == .adbServerNoAnswer)
        #expect(sleeps.sleeps.reduce(.zero, +) == .seconds(5))
    }
}
