import Foundation
import Testing

/// Selectors search every root (the app window, labelled with its title, and the keyboard), so each test checks the app's readout.
@Suite("Android selectors", .serialized, .enabled(if: isAndroidE2EEnabled))
struct AndroidSelectorTests {
    @Test("--label on a switch toggles it")
    func switchByLabel() async throws {
        try await AndroidE2E.open("switch-test", waitingFor: "swiftui-weather-alerts-switch")
        let result = try await AndroidE2E.run("tap --label 'SwiftUI Weather Alerts'")
        #expect(result.stdout.contains("Tap on label=SwiftUI Weather Alerts at ("), "stdout: \(result.stdout)")
        _ = try await AndroidE2E.waitForLabel(of: "swiftui-weather-alerts-state") { $0 == "SwiftUI Weather Alerts: On" }
        #expect(try await AndroidE2E.label(of: "uikit-weather-alerts-state") == "UIKit Weather Alerts: Off")
    }

    @Test("--label selects a tab")
    func tabByLabel() async throws {
        try await AndroidE2E.open("tab-view-test", waitingFor: "tab-view-tab-settings")
        try await AndroidE2E.run("tap --label Settings")
        _ = try await AndroidE2E.waitForLabel(of: "tab-view-current-tab") { $0 == "Current Tab: Settings" }
    }

    @Test("a header picker segment is tapped by id or by label and role", arguments: [
        ("--id toolbar-picker-test-filter-unread", "Unread"), ("--label Read --element-type radioButton", "Read"),
    ])
    func toolbarPicker(selector: String, filter: String) async throws {
        try await AndroidE2E.open("toolbar-picker-test", waitingFor: "toolbar-picker-test-filter-all")
        try await AndroidE2E.run("tap \(selector)")
        _ = try await AndroidE2E.waitForLabel(of: "toolbar-picker-test-state") { $0 == "Toolbar Picker State: \(filter)" }
    }

    @Test("an alert's buttons are tapped by their Android id or their label", arguments: [
        ("--id button1", "Deleted"), ("--label CANCEL", "Cancelled"),
    ])
    func alertButtons(selector: String, state: String) async throws {
        try await AndroidE2E.open("alert-test", waitingFor: "alert-test-show-alert")
        try await AndroidE2E.run("tap --id alert-test-show-alert")
        _ = try await AndroidE2E.waitForNode { ($0["id"] as? String)?.hasSuffix(":id/button1") == true }
        try await AndroidE2E.run("tap \(selector)")
        _ = try await AndroidE2E.waitForLabel(of: "alert-test-state") { $0 == "Alert State: \(state)" }
    }

    @Test("a selector tap right after each of five window changes finds the app's window")
    func tapAfterWindowChanges() async throws {
        try await AndroidE2E.open("modal-navigation-test", waitingFor: "modal-navigation-test-open")
        for _ in 1...5 {
            try await tapOnceShown("modal-navigation-test-open")
            try await tapOnceShown("modal-navigation-test-done")
        }
        try await tapOnceShown("modal-navigation-test-open")
        try await tapOnceShown("modal-navigation-test-detail-link")
        try await tapOnceShown("modal-navigation-test-complete")
        try await tapOnceShown("modal-navigation-test-back")
        try await tapOnceShown("modal-navigation-test-done")
        _ = try await AndroidE2E.waitForLabel(of: "modal-navigation-test-state") { $0 == "Modal Navigation State: Completed" }
    }

    /// Repeats a plain tap only while its target is not on screen yet (exit 2): `--wait-timeout` would also retry finding no window, which this test catches.
    private func tapOnceShown(_ id: String, timeout: TimeInterval = 20) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        var result = try await AndroidE2E.offsider("tap --id \(id)")
        while result.exitCode == 2, Date() < deadline {
            try await Task.sleep(for: .milliseconds(100))
            result = try await AndroidE2E.offsider("tap --id \(id)")
        }
        guard result.exitCode == 0 else {
            throw AndroidE2EError(description: "offsider tap --id \(id) exited \(result.exitCode): \(result.stderr)")
        }
    }

    @Test("--label taps a row in a long list")
    func longListRow() async throws {
        try await AndroidE2E.open("long-scroll-test", waitingFor: "long-scroll-test-row-3")
        try await AndroidE2E.run("tap --label 'Long Scroll Row 3'")
        _ = try await AndroidE2E.waitForLabel(of: "long-scroll-test-state") { $0 == "Long Scroll Selected: Row 3" }
    }

    /// The emulator's navigation overlay, `gestural` or `threebutton`, from the one enabled in its category.
    static func navigationOverlay() async throws -> String? {
        let listing = try await AndroidE2E.shell("cmd overlay list")
        return listing.split(separator: "\n").first { $0.contains("[x] com.android.internal.systemui.navbar.") }
            .map { String($0.split(separator: ".").last ?? "") }
    }

    static func setNavigation(_ overlay: String) async throws {
        _ = try await AndroidE2E.shell("cmd overlay enable-exclusive --category com.android.internal.systemui.navbar.\(overlay)")
        _ = try await AndroidE2E.eventually(timeout: 15) { try await navigationOverlay() == overlay }
    }

    @Test("--id on a row under three-button navigation's bar, which Android lists only as a hidden branch, exits 2 saying so, not Did you mean")
    func hiddenRowNamed() async throws {
        // Gesture navigation lists no bar, so the test sets three-button navigation and puts the AVD's own mode back.
        let before = try await Self.navigationOverlay()
        if before != "threebutton" { try await Self.setNavigation("threebutton") }
        do {
            try await Self.tapHiddenRow()
        } catch {
            if let before, before != "threebutton" { try? await Self.setNavigation(before) }
            throw error
        }
        if let before, before != "threebutton" { try await Self.setNavigation(before) }
    }

    static func tapHiddenRow() async throws {
        try await AndroidE2E.open("long-scroll-test", waitingFor: "long-scroll-test-row-3")
        let barShown = try await AndroidE2E.eventually(timeout: 15) {
            try await AndroidE2E.shell("dumpsys window | grep -c 'Window{.* NavigationBar' || true").trimmingCharacters(in: .whitespacesAndNewlines) != "0"
        }
        #expect(barShown, "the navigation bar never came up")
        let context = try #require(try await AndroidE2E.tree()["context"] as? [String: Any])
        let branches = (context["hiddenBranches"] as? [[String: Any]]) ?? []
        let id = try #require(branches.lazy.compactMap { $0["id"] as? String }.first { $0.hasPrefix("long-scroll-test-row-") }, "no row is listed as hidden: \(branches)")

        let state = try await AndroidE2E.label(of: "long-scroll-test-state")
        let result = try await AndroidE2E.offsider("tap --id \(id) --wait-timeout 0")

        #expect(result.exitCode == 2, "\(result.stderr)")
        #expect(result.stderr.contains("is under the navigation bar"), "\(result.stderr)")
        #expect(!result.stderr.contains("Did you mean"), "\(result.stderr)")
        #expect(try await AndroidE2E.label(of: "long-scroll-test-state") == state, "the refused tap reached a row")
    }

    @Test("with the keyboard up, --id still finds the text field")
    func idWithKeyboard() async throws {
        try await AndroidE2E.open("text-input", waitingFor: "text-input-field")
        try await AndroidE2E.run("tap --id text-input-field")
        #expect(try await AndroidE2E.eventually(timeout: 20) { try await AndroidE2E.keyboardShown() }, "the keyboard never came up")

        try await AndroidE2E.run("tap --id text-input-field")
        try await AndroidE2E.run("type 'abc'")
        _ = try await AndroidE2E.waitForLabel(of: "character-count") { $0 == "Characters: 3" }
    }

    @Test("with the keyboard up, --label still finds the app's back button")
    func labelWithKeyboard() async throws {
        try await AndroidE2E.open("text-input", waitingFor: "text-input-field")
        try await AndroidE2E.run("tap --id text-input-field")
        #expect(try await AndroidE2E.eventually(timeout: 20) { try await AndroidE2E.keyboardShown() }, "the keyboard never came up")

        try await AndroidE2E.run("tap --label 'Offsider Playground'")
        _ = try await AndroidE2E.waitForNode { $0["id"] as? String == "menu-title" }
    }
}
