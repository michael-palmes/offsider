import Foundation
import Testing

@Suite("Verify Tests", .serialized, .enabled(if: isE2EEnabled))
struct VerifyTests {
    private func report(_ stdout: String) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: Data(stdout.utf8))
        return try #require(object as? [String: Any])
    }

    @Test("A tap that changes the screen verifies on the first attempt and taps once")
    func tapVerifies() async throws {
        try await TestHelpers.launchPlaygroundApp(to: "tap-test")

        let result = try await TestHelpers.runOffsiderCommandSeparated(
            "tap -x 200 -y 400 --verify --json",
            simulatorUDID: defaultSimulatorUDID
        )
        let json = try report(result.stdout)

        #expect(result.exitCode == 0)
        #expect(json["verified"] as? Bool == true)
        #expect(json["change"] as? String == "accessibility-tree")
        #expect(json["attempts"] as? Int == 1)
        #expect(result.stderr.contains("✓ Tap at (200, 400) verified"))

        let uiState = try await TestHelpers.getUIState()
        let tapCount = UIStateParser.findElementContainingLabel(in: uiState, containing: "Tap Count:")
        #expect(tapCount?.label == "Tap Count: 1")
    }

    @Test("A tap on a static label exits 5 when no retries are allowed")
    func staticTapUnverified() async throws {
        try await TestHelpers.launchPlaygroundApp(to: "slider-value-test")

        let result = try await TestHelpers.runOffsiderCommandSeparated(
            "tap --id slider-value-state --verify --verify-timeout 1 --retries 0 --json",
            simulatorUDID: defaultSimulatorUDID
        )
        let json = try report(result.stdout)

        #expect(result.exitCode == 5)
        #expect(json["dispatched"] as? String == "yes")
        #expect(json["verified"] as? Bool == false)
        #expect(json["change"] as? String == "none")
        #expect(json["attempts"] as? Int == 1)
        #expect(result.stderr.contains("nothing observable changed"))
    }

    @Test("A default retry switches tap style before giving up")
    func staticTapRetries() async throws {
        try await TestHelpers.launchPlaygroundApp(to: "slider-value-test")

        let result = try await TestHelpers.runOffsiderCommandSeparated(
            "tap --id slider-value-state --verify --verify-timeout 1 --json",
            simulatorUDID: defaultSimulatorUDID
        )
        let json = try report(result.stdout)

        #expect(result.exitCode == 5)
        #expect(json["attempts"] as? Int == 2)
        #expect(json["style"] as? String == "physical")
        #expect(result.stderr.contains("retrying with physical style"))
    }

    @Test("Verified typing lands the text once")
    func typeVerifies() async throws {
        try await TestHelpers.launchPlaygroundApp(to: "text-input")

        let result = try await TestHelpers.runOffsiderCommandSeparated(
            "type hello --verify --json",
            simulatorUDID: defaultSimulatorUDID
        )
        let json = try report(result.stdout)

        #expect(result.exitCode == 0)
        #expect(json["verified"] as? Bool == true)
        let uiState = try await TestHelpers.getUIState()
        let field = UIStateParser.findElement(in: uiState) { $0.type == "TextField" || $0.type == "TextEditor" }
        #expect(field?.value == "hello")
    }

    @Test("tap --verify --json lists the readout change")
    func tapVerifyListsChanges() async throws {
        try await TestHelpers.launchPlaygroundApp(to: "toolbar-picker-test")

        let result = try await TestHelpers.runOffsiderCommandSeparated(
            "tap --label Unread --element-type radioButton --verify --json",
            simulatorUDID: defaultSimulatorUDID
        )
        let json = try report(result.stdout)
        let changes = try #require(json["changes"] as? [[String: Any]])

        #expect(result.exitCode == 0)
        #expect(changes.contains { $0["node"] as? String == #"text "Toolbar Picker State: Unread" id=toolbar-picker-test-state"# || ($0["new"] as? String) == "Unread" })
        #expect(json["changesTruncated"] as? Int != nil)
    }

    @Test("A verified key press is delivered once")
    func keyVerifies() async throws {
        try await TestHelpers.launchPlaygroundApp(to: "key-press")

        let result = try await TestHelpers.runOffsiderCommandSeparated(
            "key 40 --verify",
            simulatorUDID: defaultSimulatorUDID
        )

        #expect(result.exitCode == 0)
        #expect(result.stdout.hasPrefix("✓ Key 40 verified"))
        let uiState = try await TestHelpers.getUIState()
        let count = UIStateParser.findElementContainingLabel(in: uiState, containing: "Key Count:")
        #expect(count?.label == "Key Count: 1")
    }

    @Test("With a tree, a tap that starts motion the tree cannot see reads as no change, so with no retries it exits 5 and taps once")
    func motionStartUnderTreeUnverified() async throws {
        try await TestHelpers.launchPlaygroundApp(to: "motion-test")

        let result = try await TestHelpers.runOffsiderCommandSeparated(
            "tap --id motion-toggle --verify --verify-timeout 1 --retries 0 --json",
            simulatorUDID: defaultSimulatorUDID
        )
        let json = try report(result.stdout)

        #expect(result.exitCode == 5)
        #expect(json["change"] as? String == "none")
        try await TestHelpers.runOffsiderCommand("tap --id motion-show-toggles", simulatorUDID: defaultSimulatorUDID)
        let uiState = try await TestHelpers.getUIState()
        #expect(UIStateParser.findElementContainingLabel(in: uiState, containing: "Toggles:")?.label == "Toggles: 1")
    }

    @Test("A tap that changes nothing on a screen already moving exits 5")
    func noOpOnMovingScreenUnverified() async throws {
        try await TestHelpers.launchPlaygroundApp(to: "motion-test")
        try await TestHelpers.runOffsiderCommand("tap --id motion-toggle", simulatorUDID: defaultSimulatorUDID)

        let result = try await TestHelpers.runOffsiderCommandSeparated(
            "tap --id motion-test-title --verify --verify-timeout 1 --retries 0 --json",
            simulatorUDID: defaultSimulatorUDID
        )
        let json = try report(result.stdout)

        #expect(result.exitCode == 5)
        #expect(json["change"] as? String == "none")
    }

    @Test("Home is verified by leaving the app")
    func homeVerifies() async throws {
        try await TestHelpers.launchPlaygroundApp(to: "button-test")

        let result = try await TestHelpers.runOffsiderCommandSeparated(
            "button home --verify --json",
            simulatorUDID: defaultSimulatorUDID
        )
        let json = try report(result.stdout)

        #expect(result.exitCode == 0)
        #expect(json["change"] as? String == "accessibility-tree")
        #expect(json["style"] is NSNull)
        let uiState = try await TestHelpers.getUIState()
        #expect(UIStateParser.findElement(in: uiState, withIdentifier: "button-test-screen") == nil)
    }
}
