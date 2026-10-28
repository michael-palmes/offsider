import Foundation
import Testing

/// What counts as on screen: a closed drawer kept mounted beneath the page, rows under a tab bar, an app keypad over its field, and pages stacked with the same labels.
@Suite("React Native on-screen rule", .serialized, .enabled(if: RNPlatform.anyEnabled))
struct ReactNativeOnScreenTests {
    @Test("a closed drawer's row is not on screen to wait, assert or describe-ui, and a tap on it is refused; once open it is", arguments: RNPlatform.enabled)
    func closedDrawerRows(platform: RNPlatform) async throws {
        let app = RNApp(platform)
        try await app.open("drawer-test")

        let waited = try await app.offsider("wait --id drawer-test-row-inbox --timeout 1")
        #expect(waited.exitCode == 5)
        #expect((waited.stdout + waited.stderr).contains("so a tap would not reach it"), "\(waited.stderr)")
        let summary = try await app.run("describe-ui --summary").stdout
        #expect(!summary.contains("\"Drawer Inbox\""), "\(summary)")
        #expect(summary.contains("# covered: "), "\(summary)")
        let tapped = try await app.offsider("tap --id drawer-test-row-archive")
        #expect(tapped.exitCode == 1, "\(tapped.stderr)")
        #expect(try await app.label(of: "drawer-test-pressed") == "Drawer Pressed: None")

        try await app.run("tap --id drawer-test-toggle")
        try await app.run("wait --id drawer-test-row-inbox --timeout 5")
        try await app.run("tap --id drawer-test-row-inbox")
        _ = try await app.waitForLabel(of: "drawer-test-pressed") { $0 == "Drawer Pressed: Drawer Inbox" }
    }

    @Test("--topmost taps the pushed page's row, not the drawer's row with the same label beneath it, and the switch under that row keeps its state", arguments: RNPlatform.enabled)
    func topmostPrefersFrontPage(platform: RNPlatform) async throws {
        let app = RNApp(platform)
        try await app.open("drawer-test")
        try await app.run("tap --id drawer-test-push")
        _ = try await app.waitForNode { $0["id"] as? String == "drawer-test-pushed-title" }

        try await app.run("tap --label 'Drawer Reminders' --topmost")

        try await app.run("tap --id drawer-test-pushed-back")
        _ = try await app.waitForLabel(of: "drawer-test-pressed") { $0 == "Drawer Pressed: Pushed Reminders" }
        try await app.run("tap --id drawer-test-push")
        _ = try await app.waitForNode { $0["id"] as? String == "drawer-test-quiet" }
        try await app.run("assert --id drawer-test-quiet --has-value 1")
    }

    @Test("a row wholly under the tab bar is refused naming the bar, and nothing is pressed", arguments: RNPlatform.enabled)
    func rowUnderTabBarRefused(platform: RNPlatform) async throws {
        let app = RNApp(platform)
        try await app.open("tab-bar-test")
        let (_, height) = try await app.screenSize()
        let hidden = try await Self.rowUnderTabBar(app, screenHeight: height)

        let result = try await app.offsider("batch --json --step \(AndroidE2E.quote("tap --id \(hidden)"))")

        #expect(result.exitCode == 1, "\(result.stderr)")
        #expect(result.stdout.contains("\"reason\":\"target_covered\""), "\(result.stdout)")
        #expect(result.stdout.contains("tab-bar-test-tab"), "\(result.stdout)")
        try await Task.sleep(for: .seconds(1))
        #expect(try await app.label(of: "tab-bar-test-pressed") == "Tab Bar Pressed: None")
    }

    @Test("on a simulator a row half under the tab bar is tapped on the part that shows", arguments: RNPlatform.enabled.filter { $0 == .ios })
    func rowHalfUnderTabBarTapped(platform: RNPlatform) async throws {
        let app = RNApp(platform)
        try await app.open("tab-bar-test")

        let result = try await app.run("tap --id tab-bar-test-home-row-12")

        #expect(result.stderr.contains("tapping the part that shows"), "\(result.stderr)")
        _ = try await app.waitForLabel(of: "tab-bar-test-pressed") { $0 == "Tab Bar Pressed: Home Row 12" }
    }

    @Test("a key of the app's keypad over its amount field is tapped without a cover warning", arguments: RNPlatform.enabled)
    func keypadKeyOverField(platform: RNPlatform) async throws {
        let app = RNApp(platform)
        try await app.open("keypad-test")
        try await app.run("tap --id keypad-test-amount")
        _ = try await app.waitForNode { $0["id"] as? String == "keypad-test-key-5" }

        let result = try await app.run("tap --id keypad-test-key-5 --fail-if-covered")

        #expect(!result.stderr.contains("covered"), "\(result.stderr)")
        _ = try await app.waitForLabel(of: "keypad-test-amount") { $0 == "Amount, 5, Points" }
    }

    @Test("--label Back with the notes page over the details page pops only the top page, warning of nothing", arguments: RNPlatform.enabled)
    func backOverBack(platform: RNPlatform) async throws {
        let app = RNApp(platform)
        try await app.open("keypad-test")
        try await app.run("tap --id keypad-test-open-details")
        try await app.run("tap --id keypad-test-open-notes")
        _ = try await app.waitForNode { $0["id"] as? String == "keypad-test-notes-title" }

        let result = try await app.run("tap --label Back --element-type button --fail-if-covered")

        #expect(!result.stderr.contains("covered"), "\(result.stderr)")
        try await app.run("wait --id keypad-test-notes-title --gone --timeout 5")
        try await app.run("assert --id keypad-test-details-title")
    }

    /// The first Home row whose top lies at or below the tab bar's top edge, so none of it shows.
    private static func rowUnderTabBar(_ app: RNApp, screenHeight: Double) async throws -> String {
        let bar = try await app.frame(of: "tab-bar-test-tab-bar")
        for row in 1...14 {
            let id = "tab-bar-test-home-row-\(row)"
            guard let frame = try? await app.frame(of: id) else { continue }
            if frame.y >= bar.y - 0.5, frame.y < screenHeight { return id }
        }
        throw DescribeUIError(description: "No Home row starts under the tab bar at \(bar.y).")
    }
}
