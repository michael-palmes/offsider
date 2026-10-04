import Foundation
import Testing

@Suite("React Native choices", .serialized, .enabled(if: RNPlatform.anyEnabled))
struct ReactNativeChoiceTests {
    @Test("radio segments select by element type on both platforms", arguments: RNPlatform.enabled)
    func radioByElementType(platform: RNPlatform) async throws {
        let app = RNApp(platform)
        try await app.open("toolbar-picker-test")

        try await app.run("tap --element-type radioButton --label Unread")

        _ = try await app.waitForLabel(of: "toolbar-picker-test-state") { $0 == "Toolbar Picker State: Unread" }
        let unread = try await app.waitForNode { $0["id"] as? String == "toolbar-picker-test-filter-unread" && $0["value"] as? String == "1" }
        #expect(unread["role"] as? String == "radioButton")
        #expect((unread["state"] as? [String: Any])?["checked"] as? Bool == true)
    }

    @Test("a React Native checkbox reports 0 then 1 after a tap, and a mixed one reads 2", arguments: RNPlatform.enabled)
    func checkboxValues(platform: RNPlatform) async throws {
        let app = RNApp(platform)
        try await app.open("choice-test")

        let terms = try await app.waitForNode { $0["id"] as? String == "choice-test-checkbox-terms" }
        #expect(terms["role"] as? String == "checkbox")
        #expect(terms["value"] as? String == "0")
        let mixed = try await app.waitForNode { $0["id"] as? String == "choice-test-checkbox-mixed" }
        #expect(mixed["value"] as? String == "2")

        try await app.run("tap --id choice-test-checkbox-terms")

        let checked = try await app.waitForNode { $0["id"] as? String == "choice-test-checkbox-terms" && $0["value"] as? String == "1" }
        #expect((checked["state"] as? [String: Any])?["checked"] as? Bool == true)
    }
}
