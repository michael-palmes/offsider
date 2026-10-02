import Foundation
import Testing

@Suite("React Native fixtures", .serialized, .enabled(if: RNPlatform.anyEnabled))
struct ReactNativeFixtureSmokeTests {
    static let routes = ["parked-sheet-test", "stack-test", "overlay-test", "rows-test", "environment-test"]

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
}
