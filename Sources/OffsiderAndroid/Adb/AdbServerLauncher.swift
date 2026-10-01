import Foundation

/// Starts the SDK's adb server when none answers; never kills or restarts a running one.
struct AdbServerLauncher {
    static let startTimeout: TimeInterval = 10
    static let retryInterval: Duration = .milliseconds(100)
    static let retryAttempts = 50

    let adb: URL

    /// Probes `host:version`; when nothing listens, runs `adb start-server` with `ADB_MDNS=0`, then retries for up to 5 s.
    func ensureRunning(client: AdbClient, host: AndroidHost) async throws {
        do {
            _ = try await client.serverVersion()
            return
        } catch let error as AndroidError where error.kind == .adbServerNotRunning {}

        var environment = host.environment
        environment["ADB_MDNS"] = "0"
        let result = try await host.processes.capture(
            executable: adb.path,
            arguments: ["start-server"],
            environment: environment,
            timeout: Self.startTimeout
        )
        guard result.status == 0 else {
            let firstLine = result.stderr.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
            throw AndroidError.adbServerStartFailed(adb: adb.path, status: result.status, detail: firstLine)
        }

        for _ in 0..<Self.retryAttempts {
            do {
                _ = try await client.serverVersion()
                return
            } catch let error as AndroidError where error.kind == .adbServerNotRunning {
                try await host.sleep(Self.retryInterval)
            }
        }
        throw AndroidError.adbServerNoAnswer(endpoint: client.endpoint.description, seconds: 5)
    }
}
