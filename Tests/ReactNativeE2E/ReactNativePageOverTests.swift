import Foundation
import Testing

/// A full page over a screen, drawn several ways, and a step screen with its own empty wrappers beside real covers: what a touch reaches, and what must still refuse.
@Suite("React Native page over a screen", .serialized, .enabled(if: RNPlatform.anyEnabled))
struct ReactNativePageOverTests {
    private static func openPage(_ app: RNApp, _ button: String = "page-over-open") async throws {
        try await app.open("page-over-test")
        try await app.run("tap --id \(button)")
        _ = try await app.waitForNode { $0["id"] as? String == "page-over-back" }
    }

    @Test("a page over a longer list is the front page: its rows count, no false beneath line, and Back leaves it", arguments: RNPlatform.enabled)
    func pageOverLongerList(platform: RNPlatform) async throws {
        let app = RNApp(platform)
        try await Self.openPage(app)

        try await app.run("wait --label 'Choice 3' --timeout 5")
        let summary = try await app.run("describe-ui --summary").stdout
        #expect(!summary.contains("under \"page-over-feed\""), "\(summary)")

        try await app.run("tap --label Back --fail-if-covered")
        _ = try await app.waitForNode { $0["id"] as? String == "page-over-open" }
    }

    @Test("--fail-if-covered taps the page's row over the feed beneath", arguments: RNPlatform.enabled)
    func rowOverFeed(platform: RNPlatform) async throws {
        let app = RNApp(platform)
        try await Self.openPage(app)

        try await app.run("tap --id page-over-choice-3 --fail-if-covered")

        _ = try await app.waitForLabel(of: "page-over-page-pressed") { $0 == "Picked: Choice 3" }
    }

    @Test("two buttons with one label take the page's, with --fail-if-covered, and the one beneath refuses", arguments: RNPlatform.enabled)
    func twinButton(platform: RNPlatform) async throws {
        let app = RNApp(platform)
        try await Self.openPage(app)

        let beneath = try await app.offsider("tap --id page-over-home-confirm --fail-if-covered")
        #expect(beneath.exitCode == 1, "\(beneath.stderr)")
        #expect(try await app.label(of: "page-over-page-pressed") == "Picked: None")

        try await app.run("tap --label Confirm --element-type button --fail-if-covered --verify --retries 0")
        _ = try await app.waitForLabel(of: "page-over-page-pressed") { $0 == "Picked: Page Confirm" }
    }

    @Test("a page drawn first and raised, or in a modal, is the front page", arguments: RNPlatform.enabled, ["page-over-open-raised", "page-over-open-modal"])
    func otherWaysToDraw(platform: RNPlatform, button: String) async throws {
        let app = RNApp(platform)
        try await Self.openPage(app, button)

        try await app.run("wait --label 'Choice 3' --timeout 5")
        try await app.run("tap --id page-over-choice-3 --fail-if-covered")
        _ = try await app.waitForLabel(of: "page-over-page-pressed") { $0 == "Picked: Choice 3" }
    }

    @Test("a page the size of the feed still covers it, so its rows are not on screen", arguments: RNPlatform.enabled)
    func samePageSize(platform: RNPlatform) async throws {
        let app = RNApp(platform)
        try await Self.openPage(app, "page-over-open-bare")

        let waited = try await app.offsider("wait --id page-over-feed-item-3 --timeout 1")

        #expect(waited.exitCode == 5, "\(waited.stderr)")
        try await app.run("assert --label 'Choice 3'")
    }

    @Test("--verify-id on a group beneath the page lets Back go, and the group's return proves it", arguments: RNPlatform.enabled)
    func verifyIdOnGroupBeneath(platform: RNPlatform) async throws {
        let app = RNApp(platform)
        try await app.open("page-over-test")
        if platform == .android {
            try await app.run("tap --id page-over-lower")
            _ = try await app.waitForNode { $0["id"] as? String == "page-over-gallery" }
        }
        try await app.run("tap --id page-over-open")
        _ = try await app.waitForNode { $0["id"] as? String == "page-over-back" }

        try await app.run("tap --label Back --fail-if-covered --verify-id \(platform == .android ? "page-over-gallery" : "page-over-feed")")

        _ = try await app.waitForNode { $0["id"] as? String == "page-over-open" }
    }

    // MARK: A screen's own wrappers and real covers

    @Test("--fail-if-covered taps a button under its screen's own empty wrappers, step after step", arguments: RNPlatform.enabled)
    func ownWrappers(platform: RNPlatform) async throws {
        let app = RNApp(platform)
        try await app.open("own-cover-test")

        try await app.run("tap --id own-cover-confirm --fail-if-covered")
        _ = try await app.waitForLabel(of: "own-cover-pressed") { $0 == "Own Pressed: Step 2" }
        try await app.run("tap --id own-cover-confirm --fail-if-covered")
        _ = try await app.waitForLabel(of: "own-cover-pressed") { $0 == "Own Pressed: Step 3" }
        try await app.run("tap --id own-cover-confirm --fail-if-covered")
        _ = try await app.waitForLabel(of: "own-cover-pressed") { $0 == "Own Pressed: Send" }
    }

    @Test("--fail-if-covered refuses every real cover over the button, and nothing is pressed", arguments: RNPlatform.enabled, ["scrim", "veil", "sheet", "control"])
    func realCoversRefuse(platform: RNPlatform, cover: String) async throws {
        let app = RNApp(platform)
        try await app.open("own-cover-test")
        try await app.run("tap --id own-cover-show-\(cover)")
        try await Task.sleep(for: .seconds(1))

        let result = try await app.offsider("batch --json --step \(AndroidE2E.quote("tap --id own-cover-confirm --fail-if-covered"))")

        #expect(result.exitCode == 1, "\(result.stdout) \(result.stderr)")
        #expect(result.stdout.contains("\"reason\":\"target_covered\""), "\(result.stdout)")
        #expect(result.stdout.contains("\"dispatched\":\"no\""), "\(result.stdout)")
        try await Task.sleep(for: .seconds(1))
        #expect(try await app.label(of: "own-cover-pressed") == "Own Pressed: None")
    }
}
