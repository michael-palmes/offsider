import Foundation
import Testing

@Suite("Logs on the simulator", .serialized, .enabled(if: isE2EEnabled))
struct LogsTests {
    struct Logs: Decodable {
        struct Entry: Decodable {
            let timestamp: String
            let level: String
            let process: String?
            let message: String
        }
        let version: Int
        let platform: String
        let device: String
        let entries: [Entry]
        let truncated: Int
    }

    @Test("logs --process --json prints the documented shape for the playground")
    func processJSON() async throws {
        let udid = try TestHelpers.requireSimulatorUDID()
        try await TestHelpers.launchPlaygroundApp(to: "button-test")

        let result = try await TestHelpers.runOffsiderCommandSeparated("logs --process OffsiderPlayground --last 1m --json", simulatorUDID: udid)

        #expect(result.exitCode == 0, "\(result.stderr)")
        let logs = try JSONDecoder().decode(Logs.self, from: Data(result.stdout.utf8))
        #expect(logs.version == 1)
        #expect(logs.platform == "ios")
        #expect(logs.device == udid)
        #expect(!logs.entries.isEmpty, "a launch within the last minute should log something")
        #expect(logs.entries.allSatisfy { $0.process == "OffsiderPlayground" })
        #expect(logs.truncated >= 0)
    }

    @Test("logs --app reads an installed app's process")
    func installedApp() async throws {
        try await TestHelpers.launchPlaygroundApp(to: "button-test")

        let result = try await TestHelpers.runOffsiderCommandSeparated("logs --app com.mpalmes.offsider.playground --last 30s", simulatorUDID: defaultSimulatorUDID)

        #expect(result.exitCode == 0, "\(result.stderr)")
    }

    @Test("logs --app refuses an app that is not installed")
    func missingApp() async throws {
        let result = try await TestHelpers.runOffsiderCommandSeparated("logs --app com.example.not.installed", simulatorUDID: defaultSimulatorUDID)

        #expect(result.exitCode != 0)
        #expect(result.stderr.contains("App com.example.not.installed is not installed"), "\(result.stderr)")
    }
}
