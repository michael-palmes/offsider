import Foundation
import Testing

@Suite("React Native stacked pages and covers", .serialized, .enabled(if: RNPlatform.anyEnabled))
struct ReactNativeStackCoverTests {
    /// Opens stack-test with full page 1 drawn over the mounted stack and its tab row.
    private static func openFullPage(_ app: RNApp) async throws {
        try await app.open("stack-test")
        try await app.run("tap --id stack-test-open-full")
        _ = try await app.waitForNode { $0["id"] as? String == "stack-test-full-title-1" }
    }

    private static func batchError(_ stdout: String) throws -> [String: Any] {
        let line = try #require(stdout.split(separator: "\n").first, "\(stdout)")
        let object = try #require(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any], "\(stdout)")
        return try #require(object["error"] as? [String: Any], "\(stdout)")
    }

    @Test("the Dashboard Tab under the page's Buy button is refused, naming Buy, and nothing is pressed", arguments: RNPlatform.enabled)
    func coveredTabRefused(platform: RNPlatform) async throws {
        let app = RNApp(platform)
        try await Self.openFullPage(app)

        let result = try await app.offsider("batch --json --step \(AndroidE2E.quote("tap --id stack-test-tab-dashboard"))")

        #expect(result.exitCode == 1, "\(result.stderr)")
        let error = try Self.batchError(result.stdout)
        #expect(error["reason"] as? String == "target_covered")
        #expect(error["dispatched"] as? String == "no")
        let cover = try #require(error["coveredBy"] as? [String: Any], "\(error)")
        #expect(cover["id"] as? String == "stack-test-full-buy")
        #expect(cover["evidence"] as? String == (platform == .ios ? "hitTest" : "drawingOrder"))
        try await Task.sleep(for: .seconds(1))
        #expect(try await app.label(of: "stack-test-state") == "Stack State: Initial")
    }

    @Test("--allow-covered taps through to Buy with a warning", arguments: RNPlatform.enabled)
    func allowCoveredTapsBuy(platform: RNPlatform) async throws {
        let app = RNApp(platform)
        try await Self.openFullPage(app)

        let result = try await app.run("tap --id stack-test-tab-dashboard --allow-covered")

        #expect(result.stderr.contains("tapping anyway because of --allow-covered"), "\(result.stderr)")
        _ = try await app.waitForLabel(of: "stack-test-state") { $0 == "Stack State: Buy pressed" }
    }

    @Test("Open Flags over Open Full Page taps without a warning", arguments: RNPlatform.enabled)
    func pageButtonOverBaseButton(platform: RNPlatform) async throws {
        let app = RNApp(platform)
        try await Self.openFullPage(app)

        let result = try await app.run("tap --id stack-test-full-next")

        #expect(!result.stderr.contains("Warning"), "\(result.stderr)")
        _ = try await app.waitForLabel(of: "stack-test-full-depth") { $0 == "Full Page Depth: 2" }
    }

    @Test("--label Back with both pages open pops only the top page", arguments: RNPlatform.enabled)
    func stackedBackPopsOne(platform: RNPlatform) async throws {
        let app = RNApp(platform)
        try await Self.openFullPage(app)
        try await app.run("tap --id stack-test-full-next")
        _ = try await app.waitForLabel(of: "stack-test-full-depth") { $0 == "Full Page Depth: 2" }

        try await app.run("tap --label Back")

        _ = try await app.waitForLabel(of: "stack-test-full-depth") { $0 == "Full Page Depth: 1" }
        try await Task.sleep(for: .seconds(1))
        #expect(try await app.label(of: "stack-test-full-depth") == "Full Page Depth: 1")
    }

    @Test("--wait-timeout outlasts a page that closes on its own, then taps the tab beneath", arguments: RNPlatform.enabled)
    func waitOutlastsClosingPage(platform: RNPlatform) async throws {
        let app = RNApp(platform)
        try await Self.openFullPage(app)
        try await app.run("tap --id stack-test-full-close-later")

        let result = try await app.offsider("tap --id stack-test-tab-dashboard --wait-timeout 3")

        #expect(result.exitCode == 0, "\(result.stderr)")
        _ = try await app.waitForLabel(of: "stack-test-state") { $0 == "Stack State: Tab: Dashboard" }
    }

    @Test("--summary folds the mounted stack beneath the page on Android; iOS lists a React Native overlay page flat, so nothing folds", arguments: RNPlatform.enabled)
    func summaryFoldsCoveredScreen(platform: RNPlatform) async throws {
        let app = RNApp(platform)
        try await Self.openFullPage(app)

        let summary = try await app.run("describe-ui --summary").stdout

        #expect(summary.contains("id=stack-test-full-buy"), "\(summary)")
        switch platform {
        case .android:
            #expect(!summary.contains("id=stack-test-tab-dashboard"), "\(summary)")
            #expect(summary.contains("# beneath: \"Mounted Stack\""), "\(summary)")
            #expect(summary.contains("under \"stack-test-full-page-1\""), "\(summary)")
        case .ios:
            #expect(summary.contains("id=stack-test-tab-dashboard") && !summary.contains("# beneath:"), "\(summary)")
        }
    }
}

