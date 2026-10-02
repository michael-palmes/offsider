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

    @Test("--label taps a row in a long list")
    func longListRow() async throws {
        try await AndroidE2E.open("long-scroll-test", waitingFor: "long-scroll-test-row-3")
        try await AndroidE2E.run("tap --label 'Long Scroll Row 3'")
        _ = try await AndroidE2E.waitForLabel(of: "long-scroll-test-state") { $0 == "Long Scroll Selected: Row 3" }
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
