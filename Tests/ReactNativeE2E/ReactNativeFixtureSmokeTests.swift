import Foundation
import Testing

@Suite("React Native fixtures", .serialized, .enabled(if: RNPlatform.anyEnabled))
struct ReactNativeFixtureSmokeTests {
    static let routes = ["parked-sheet-test", "stack-test", "overlay-test", "rows-test", "environment-test", "live-ticker"]

    @Test("each fixture route opens on its marker", arguments: RNPlatform.enabled, routes)
    func routeOpens(platform: RNPlatform, route: String) async throws {
        try await RNApp(platform).open(route)
    }

    @Test("the parked sheet starts parked and opens on request", arguments: RNPlatform.enabled)
    func parkedSheetOpens(platform: RNPlatform) async throws {
        let app = RNApp(platform)
        try await app.open("parked-sheet-test")

        #expect(try await app.label(of: "parked-sheet-test-state") == "Parked Sheet State: Initial")
        #expect(try await app.label(of: "parked-sheet-test-position") == "Sheet Position: Parked")

        try await app.run("tap --id parked-sheet-test-open")
        _ = try await app.waitForLabel(of: "parked-sheet-test-position") { $0 == "Sheet Position: Open" }
    }

    @Test("a banner over the tab bar swallows a coordinate tap", arguments: RNPlatform.enabled)
    func bannerSwallowsTap(platform: RNPlatform) async throws {
        let app = RNApp(platform)
        try await app.open("overlay-test")
        let search = try await app.centre(of: "overlay-test-tab-search")

        try await app.run("tap --id overlay-test-toggle-banner")
        _ = try await app.waitForNode { $0["id"] as? String == "overlay-test-banner" }
        try await app.run("tap -x \(search.x) -y \(search.y)")

        _ = try await app.waitForLabel(of: "overlay-test-swallowed") { $0 == "Swallowed Taps: 1" }
        #expect(try await app.label(of: "overlay-test-tab") == "Overlay Tab: Home")
    }

    @Test("a control hidden from accessibility still takes a coordinate tap", arguments: RNPlatform.enabled)
    func hiddenControlTakesCoordinateTap(platform: RNPlatform) async throws {
        let app = RNApp(platform)
        try await app.open("overlay-test")
        let ids = DescribeUITree.nodes(in: try await app.tree()).compactMap { $0["id"] as? String }
        #expect(!ids.contains("overlay-test-hidden-action"))

        let frame = try await app.centre(of: "overlay-test-hidden-frame")
        try await app.run("tap -x \(frame.x) -y \(frame.y)")

        _ = try await app.waitForLabel(of: "overlay-test-hidden-taps") { $0 == "Hidden Taps: 1" }
    }

    @Test("rows show a live download value and start unselected", arguments: RNPlatform.enabled)
    func rowsHaveLiveValue(platform: RNPlatform) async throws {
        let app = RNApp(platform)
        try await app.open("rows-test")

        #expect(try await app.label(of: "rows-test-state") == "Rows Selected: None")
        let first = try await app.label(of: "rows-test-download")
        try await Task.sleep(for: .milliseconds(2_500))
        let second = try await app.label(of: "rows-test-download")

        #expect(first != nil)
        #expect(first != second, "the download row should change on its own")
    }

    @Test("the environment screen reports scheme, orientation and its log count", arguments: RNPlatform.enabled)
    func environmentReadouts(platform: RNPlatform) async throws {
        let app = RNApp(platform)
        try await app.open("environment-test")

        #expect(try await app.label(of: "environment-test-scheme")?.hasPrefix("Colour Scheme: ") == true)
        #expect(try await app.label(of: "environment-test-orientation") == "Orientation: portrait")
        #expect(try await app.label(of: "environment-test-log-count") == "Log Count: 0")

        try await app.run("tap --id environment-test-log")
        _ = try await app.waitForLabel(of: "environment-test-log-count") { $0 == "Log Count: 1" }
    }

    @Test("the summary names an open keyboard", arguments: RNPlatform.enabled)
    func keyboardHeader(platform: RNPlatform) async throws {
        let app = RNApp(platform)
        try await app.open("text-input")
        try await app.run("tap --id text-input-field")
        _ = try await app.waitForNode { $0["id"] as? String == "typing-active-indicator" }
        try await Task.sleep(for: .seconds(1))

        let summary = try await app.run("describe-ui --summary").stdout

        #expect(summary.contains("\n# keyboard shown\n"), "\(summary.prefix(300))")
    }

    @Test("on Android an open React Native Modal is named as a modal window", .enabled(if: isAndroidE2EEnabled))
    func modalHeader() async throws {
        let app = RNApp(.android)
        try await app.open("modal-navigation-test")
        try await app.run("tap --id modal-navigation-test-open")
        _ = try await app.waitForNode { $0["id"] as? String == "modal-navigation-test-modal" }

        let summary = try await app.run("describe-ui --summary").stdout

        #expect(summary.contains("(modal)\n"), "\(summary.prefix(300))")
    }

    @Test("type --into-id lands in the second field while the first has focus", arguments: RNPlatform.enabled)
    func typeIntoSecondField(platform: RNPlatform) async throws {
        let app = RNApp(platform)
        try await app.open("text-input")
        try await app.run("tap --id text-input-field")
        _ = try await app.waitForNode { $0["id"] as? String == "typing-active-indicator" }

        let command = "type --into-id text-input-second-field --replace 'second'"
        let first = try await app.offsider(command)
        if first.exitCode != 0 {
            // A short screen, such as a Fold's inner display, can put the second field under the keyboard, which type refuses unsent.
            try #require(
                platform == .android && first.exitCode == 1 && first.stderr.contains("The keyboard covers --id 'text-input-second-field'"),
                "offsider \(command) exited \(first.exitCode): \(first.stderr)"
            )
            try await app.run("button back")
            try await Self.waitForKeyboardHidden(app)
            try await app.run(command)
        }

        _ = try await app.waitForLabel(of: "text-input-second-value") { $0 == "Second: second" }
        #expect(try await app.label(of: "character-count") == nil)
    }

    /// Polls describe-ui until its context reports no keyboard.
    static func waitForKeyboardHidden(_ app: RNApp, timeout: TimeInterval = 10) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while (try await app.tree()["context"] as? [String: Any])?["keyboard"] as? Bool != false {
            guard Date() < deadline else {
                throw DescribeUIError(description: "the keyboard was still up \(Int(timeout)) s after button back")
            }
            try await Task.sleep(for: .milliseconds(250))
        }
    }

    @Test("on Android --require-focus-id with the other field focused is exit 2 and types nothing", .enabled(if: isAndroidE2EEnabled))
    func requireFocusMismatch() async throws {
        let app = RNApp(.android)
        try await app.open("text-input")
        try await app.run("tap --id text-input-field")
        _ = try await app.waitForNode { $0["id"] as? String == "typing-active-indicator" }

        let result = try await app.offsider("type --require-focus-id text-input-second-field 'nope'")

        #expect(result.exitCode == 2, "\(result.stderr)")
        #expect(try await app.label(of: "character-count") == nil)
    }

    @Test("on Android a field that keeps two characters refuses longer replacement text with text_not_accepted", .enabled(if: isAndroidE2EEnabled))
    func textNotAccepted() async throws {
        let app = RNApp(.android)
        try await app.open("text-input")

        let result = try await app.offsider("type --into-id text-input-short-field --replace 'four'")

        #expect(result.exitCode == 5, "\(result.stderr)")
        #expect(result.stderr.contains("text-input-short-field"), "\(result.stderr)")
    }
}
