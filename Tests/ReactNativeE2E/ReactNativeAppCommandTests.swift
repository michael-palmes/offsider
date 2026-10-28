import Foundation
import Testing

@Suite("App commands", .serialized, .enabled(if: RNPlatform.anyEnabled))
struct ReactNativeAppCommandTests {
    static let app = "com.mpalmes.offsider.playground.rn"

    static func json(_ output: SeparatedCommandOutput) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: Data(output.stdout.utf8)) as? [String: Any])
    }

    @Test("app info reads the installed playground's version and build", arguments: RNPlatform.enabled)
    func info(platform: RNPlatform) async throws {
        let app = RNApp(platform)
        try await app.open("rows-test")
        let info = try Self.json(try await app.run("app info --app \(Self.app) --json"))
        #expect(info["appVersion"] as? String == "1.0.0")
        #expect(info["build"] as? String == "1")
        #expect(info["app"] as? String == Self.app)
    }

    @Test("stop ends the app, launch then starts it cold on its menu, and a second launch is warm", arguments: RNPlatform.enabled)
    func stopThenLaunch(platform: RNPlatform) async throws {
        let app = RNApp(platform)
        try await app.open("rows-test")
        #expect(try Self.json(try await app.run("app stop --app \(Self.app) --json"))["wasRunning"] as? Bool == true)
        #expect(try Self.json(try await app.run("app stop --app \(Self.app) --json"))["wasRunning"] as? Bool == false)

        let cold = try Self.json(try await app.run("app launch --app \(Self.app) --json"))
        #expect(cold["start"] as? String == "cold")
        _ = try await app.waitForNode(timeout: 40) { $0["id"] as? String == "menu-title" }

        let warm = try Self.json(try await app.run("app launch --app \(Self.app) --json"))
        #expect(warm["start"] as? String == "warm")
    }

    @Test("a deep link reaches the named app and opens its screen, cold with --restart", arguments: RNPlatform.enabled)
    func openLink(platform: RNPlatform) async throws {
        let app = RNApp(platform)
        try await app.open("rows-test")
        try await app.run("app open 'offsiderplaygroundrn://screen/live-ticker' --app \(Self.app)")
        _ = try await app.waitForNode(timeout: 20) { $0["id"] as? String == "live-ticker-screen" }

        let restarted = try Self.json(try await app.run("app open 'offsiderplaygroundrn://screen/rows-test' --restart --app \(Self.app) --json"))
        #expect(restarted["start"] as? String == "cold")
        _ = try await app.waitForNode(timeout: 40) { $0["id"] as? String == "rows-test-screen" }
    }

    @Test("a link no screen of the app takes exits 1 with link_not_handled", arguments: RNPlatform.enabled)
    func unhandledLink(platform: RNPlatform) async throws {
        let app = RNApp(platform)
        try await app.open("rows-test")
        let result = try await app.offsider("app open 'offsider-nowhere://screen/x' --app \(Self.app) --json")
        #expect(result.exitCode == 1)
        #expect((result.stdout + result.stderr).contains("link_not_handled"))
    }
}
