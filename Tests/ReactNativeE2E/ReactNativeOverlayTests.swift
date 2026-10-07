import Foundation
import Testing

@Suite("React Native overlays", .serialized, .enabled(if: RNPlatform.anyEnabled))
struct ReactNativeOverlayTests {
    static let bannerText = "Connection lost. Can’t reach the server."

    /// iOS maps the accessible banner View to `other`; Android maps it to a labelled `group`.
    private static func coverText(_ platform: RNPlatform) -> String {
        switch platform {
        case .ios: return "is covered by other '\(bannerText)'"
        case .android: return "is covered by group '\(bannerText)'"
        }
    }

    private static func openWithBanner(_ app: RNApp) async throws {
        try await app.open("overlay-test")
        try await app.run("tap --id overlay-test-toggle-banner")
        _ = try await app.waitForNode { $0["id"] as? String == "overlay-test-banner" }
    }

    @Test("a tab under a banner is refused, naming the banner, and --allow-covered lets the banner swallow it", arguments: RNPlatform.enabled)
    func coveredTabRefused(platform: RNPlatform) async throws {
        let app = RNApp(platform)
        try await Self.openWithBanner(app)

        let refused = try await app.offsider("tap --id overlay-test-tab-search")

        #expect(refused.exitCode == 1, "\(refused.stderr)")
        #expect(refused.stderr.contains(Self.coverText(platform)), "\(refused.stderr)")
        try await Task.sleep(for: .seconds(1))
        #expect(try await app.label(of: "overlay-test-swallowed") == "Swallowed Taps: 0")

        let allowed = try await app.offsider("tap --id overlay-test-tab-search --allow-covered")

        #expect(allowed.exitCode == 0, "\(allowed.stderr)")
        #expect(allowed.stderr.contains(Self.coverText(platform)), "\(allowed.stderr)")
        _ = try await app.waitForLabel(of: "overlay-test-swallowed") { $0 == "Swallowed Taps: 1" }
        #expect(try await app.label(of: "overlay-test-tab") == "Overlay Tab: Home")
    }

    @Test("--fail-if-covered stops before the banner swallows the tap", arguments: RNPlatform.enabled)
    func failIfCoveredStops(platform: RNPlatform) async throws {
        let app = RNApp(platform)
        try await Self.openWithBanner(app)

        let result = try await app.offsider("tap --id overlay-test-tab-search --fail-if-covered")

        #expect(result.exitCode == 1)
        #expect(result.stderr.contains(Self.coverText(platform)), "\(result.stderr)")
        try await Task.sleep(for: .seconds(1))
        #expect(try await app.label(of: "overlay-test-swallowed") == "Swallowed Taps: 0")
        #expect(try await app.label(of: "overlay-test-tab") == "Overlay Tab: Home")
    }

    @Test("tapping the banner itself does not warn", arguments: RNPlatform.enabled)
    func bannerItselfDoesNotWarn(platform: RNPlatform) async throws {
        let app = RNApp(platform)
        try await Self.openWithBanner(app)

        let result = try await app.run("tap --id overlay-test-banner --fail-if-covered")

        #expect(!result.stderr.contains("may be covered"), "\(result.stderr)")
        _ = try await app.waitForLabel(of: "overlay-test-swallowed") { $0 == "Swallowed Taps: 1" }
    }

    @Test("with the banner hidden the tab changes and nothing warns", arguments: RNPlatform.enabled)
    func uncoveredTabTaps(platform: RNPlatform) async throws {
        let app = RNApp(platform)
        try await app.open("overlay-test")

        let result = try await app.run("tap --id overlay-test-tab-search --fail-if-covered")

        #expect(!result.stderr.contains("Warning"), "\(result.stderr)")
        _ = try await app.waitForLabel(of: "overlay-test-tab") { $0 == "Overlay Tab: Search" }
    }

    @Test("known limit: a scrim hidden from accessibility swallows a selector tap without a warning", arguments: RNPlatform.enabled)
    func silentScrimIsNotDetected(platform: RNPlatform) async throws {
        let app = RNApp(platform)
        try await app.open("overlay-test")
        // The hidden scrim leaves the tree unchanged, so only its readout shows that it has mounted.
        let steps = [
            "tap --id overlay-test-show-scrim",
            "wait --label 'Scrim: Shown'",
            "tap --id overlay-test-tab-search --fail-if-covered",
        ]
        let result = try await app.run("batch " + steps.map { "--step \(AndroidE2E.quote($0))" }.joined(separator: " "))

        #expect(!result.stderr.contains("may be covered"), "\(result.stderr)")
        _ = try await app.waitForLabel(of: "overlay-test-swallowed") { $0 == "Swallowed Taps: 1" }
        #expect(try await app.label(of: "overlay-test-tab") == "Overlay Tab: Home")
    }

    @Test("wait --gone does not count a node that flickers out for 300 ms as gone", arguments: RNPlatform.enabled)
    func flickerIsNotGone(platform: RNPlatform) async throws {
        let app = RNApp(platform)
        try await app.open("overlay-test")
        try await app.run("tap --id overlay-test-flicker")

        // The node is back for 1.2 s between flickers, longer than a slow read takes, so no two reads both land in a gap.
        let result = try await app.offsider("wait --label 'Flickering Node' --gone --timeout 3")

        #expect(result.exitCode == 5, "\(result.stderr)")
    }

    @Test("wait --any reports the selector that came on screen", arguments: RNPlatform.enabled)
    func waitAny(platform: RNPlatform) async throws {
        let app = RNApp(platform)
        try await app.open("overlay-test")

        let result = try await app.run("wait --any --id never-there --id overlay-test-tab --json --timeout 5")

        #expect(result.stdout.contains(#""matched":{"by":"id","text":"overlay-test-tab"}"#), "\(result.stdout)")
    }

    @Test("--verify-ignore-text does not count a ticking clock as the effect of a tap that does nothing", arguments: RNPlatform.enabled)
    func ignoreTextOnTickingScreen(platform: RNPlatform) async throws {
        let app = RNApp(platform)
        try await app.open("overlay-test")
        try await app.run("tap --id overlay-test-start-clock")
        _ = try await app.waitForLabel(of: "overlay-test-clock") { $0 != "Clock: 0" }

        let result = try await app.offsider("tap --id overlay-test-tab --verify-ignore-text --retries 0")

        #expect(result.exitCode == 5, "\(result.stderr)")
    }
}
