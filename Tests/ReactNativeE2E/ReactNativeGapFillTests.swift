import Foundation
import Testing

/// What an app draws but hides from accessibility: a tab panel's other tabs, a side panel, a page pushed over a listed one, and a sheet that must keep what lies beneath it out.
@Suite("React Native elements hidden from accessibility", .serialized, .enabled(if: RNPlatform.anyEnabled), StylusHandwritingOff())
struct ReactNativeGapFillTests {
    @Test("a screen that hides nothing lists nothing as filled", arguments: RNPlatform.enabled)
    func nothingHidden(platform: RNPlatform) async throws {
        let app = RNApp(platform)
        try await app.open("gap-tabs-test")
        let summary = try await app.run("describe-ui --summary").stdout
        #expect(!summary.contains("# filled:"), "\(summary)")
        #expect(summary.contains("\"Home Item 2\""), "\(summary)")
    }

    @Test("a hidden tab's rows are listed once on screen, and selectors find and tap them", arguments: RNPlatform.enabled)
    func hiddenTabRows(platform: RNPlatform) async throws {
        let app = RNApp(platform)
        try await app.open("gap-tabs-test")
        try await app.run("tap --id gap-tabs-tab-saved")
        _ = try await app.waitForLabel(of: "gap-tabs-pressed") { $0 == "Gap Pressed: Saved Tab" }

        let summary = try await app.run("describe-ui --summary").stdout
        #expect(summary.contains("# filled: "), "\(summary)")
        #expect(summary.contains("id=gap-tabs-saved-row-4"), "\(summary)")
        #expect(summary.components(separatedBy: "id=gap-tabs-saved-row-4 ").count == 2, "\(summary)")

        try await app.run("wait --label 'Saved Item 5' --timeout 5")
        try await app.run("assert --id gap-tabs-saved-row-6")
        try await app.run("tap --label 'Saved Item 4' --verify")
        _ = try await app.waitForLabel(of: "gap-tabs-pressed") { $0 == "Gap Pressed: Saved Item 4" }
    }

    @Test("a hidden field is listed, its password stays masked and a screenshot paints a masked row", arguments: RNPlatform.enabled)
    func hiddenFieldsAndMasks(platform: RNPlatform) async throws {
        let app = RNApp(platform)
        try await app.open("gap-tabs-test")
        try await app.run("tap --id gap-tabs-tab-search")
        _ = try await app.waitForLabel(of: "gap-tabs-pressed") { $0 == "Gap Pressed: Search Tab" }

        let summary = try await app.run("describe-ui --summary").stdout
        #expect(summary.contains("id=gap-tabs-search-field"), "\(summary)")
        #expect(summary.contains("secureTextField"), "\(summary)")
        #expect(!summary.contains("4821-fixture"), "\(summary)")

        try await app.run("type abc --into-id gap-tabs-search-field")
        let typed = try await app.run("describe-ui --summary").stdout
        let field = typed.split(separator: "\n").filter { $0.contains("id=gap-tabs-search-field ") }
        #expect(field.contains { $0.contains(#"value="abc""#) }, "the text did not land in the app's field: \(typed)")

        let path = NSTemporaryDirectory() + "offsider-gap-\(UUID().uuidString).png"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let shot = try await app.run("screenshot --mask-id gap-tabs-passcode --output \(path) --json").stdout
        #expect(!shot.contains("\"maskUnmatched\":[\"id"), "\(shot)")
        #expect(shot.contains("\"id\":1"), "\(shot)")
    }

    @Test("a hidden side panel's buttons are listed and tapped", arguments: RNPlatform.enabled)
    func hiddenPanel(platform: RNPlatform) async throws {
        let app = RNApp(platform)
        try await app.open("gap-tabs-test")
        try await app.run("tap --id gap-tabs-open-panel")

        try await app.run("wait --label 'Archive All' --timeout 5")
        try await app.run("tap --label 'Archive All'")
        try await app.run("tap --label 'Cancel Archive'")
        try await app.run("wait --id gap-tabs-pressed --timeout 5")
        _ = try await app.waitForLabel(of: "gap-tabs-pressed") { $0 == "Gap Pressed: Archive All" }
    }

    @Test("on Android a hidden page counts as over the listed rows it covers, so they drop from --on-screen and a tap refuses")
    func hiddenPageOnAndroid() async throws {
        guard RNPlatform.enabled.contains(.android) else { return }
        let app = RNApp(.android)
        try await app.open("gap-tabs-test")
        try await app.run("tap --id gap-tabs-open-page")
        try await app.run("wait --label 'Page Action' --timeout 5")

        let onScreen = try await app.run("describe-ui --summary --on-screen").stdout
        #expect(onScreen.contains("\"Page Action\""), "\(onScreen)")
        #expect(!onScreen.contains("\"Home Item 2\""), "\(onScreen)")

        let tapped = try await app.offsider("tap --id gap-tabs-home-row-2 --fail-if-covered")
        #expect(tapped.exitCode != 0, "\(tapped.stdout)")
        try await app.run("tap --id gap-tabs-page-action")
        _ = try await app.waitForLabel(of: "gap-tabs-pressed") { $0 == "Gap Pressed: Page Action" }
    }

    @Test("what a hiding sheet's backdrop covers stays out of the tree", arguments: RNPlatform.enabled)
    func coveredStaysOut(platform: RNPlatform) async throws {
        let app = RNApp(platform)
        try await app.open("mask-sheet-test")
        try await app.run("tap --id mask-sheet-test-open-hiding")
        _ = try await app.waitForNode { $0["id"] as? String == "mask-sheet-test-close" }

        let summary = try await app.run("describe-ui --summary").stdout
        #expect(!summary.contains("mask-sheet-test-address"), "\(summary)")
        try await app.run("tap --id mask-sheet-test-close")
    }
}
