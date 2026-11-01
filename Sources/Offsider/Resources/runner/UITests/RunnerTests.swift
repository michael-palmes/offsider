import XCTest

/// One test that serves Offsider's requests until it goes idle or is told to stop.
final class RunnerTests: XCTestCase {
    func testServe() throws {
        let environment = ProcessInfo.processInfo.environment
        let token = try XCTUnwrap(environment["OFFSIDER_RUNNER_TOKEN"].flatMap { $0.isEmpty ? nil : $0 }, "OFFSIDER_RUNNER_TOKEN is required")
        let port = UInt16(environment["OFFSIDER_RUNNER_PORT"] ?? "") ?? 0
        let idle = TimeInterval(environment["OFFSIDER_RUNNER_IDLE_SECONDS"] ?? "").flatMap { $0 > 0 ? $0 : nil } ?? 300
        let commands = RunnerCommands(buildKey: environment["OFFSIDER_RUNNER_BUILD_KEY"] ?? "")
        let server = try RunnerServer(port: port, token: token, handler: commands.handle)
        let done = expectation(description: "stop or idle")
        var finished = false
        let finish = {
            guard !finished else { return }
            finished = true
            done.fulfill()
        }

        server.start(
            ready: { bound in
                NSLog("OFFSIDER_RUNNER_PORT=%d", Int(bound))
                NSLog("OFFSIDER_RUNNER_READY")
            },
            failed: { message in
                NSLog("OFFSIDER_RUNNER_FAILED %@", message)
                DispatchQueue.main.async(execute: finish)
            }
        )
        let keepalive = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            if commands.stopRequested || Date().timeIntervalSince(commands.lastActivity) > idle { finish() }
        }
        wait(for: [done], timeout: 7 * 24 * 3600)
        keepalive.invalidate()
        server.stop()
    }
}
