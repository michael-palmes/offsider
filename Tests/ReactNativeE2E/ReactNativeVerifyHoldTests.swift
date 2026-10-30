import Foundation
import Testing

/// `--verify` holding its retry while a push is on its way, and `--verify-id` for the page a Back returns to.
@Suite("React Native verify holds and --verify-id front", .serialized, .enabled(if: RNPlatform.anyEnabled))
struct ReactNativeVerifyHoldTests {
    @Test("a tap whose loader ticks and goes before its page lands, after the verify window, is watched instead of pressed again", arguments: RNPlatform.enabled)
    func slowPushIsTappedOnce(platform: RNPlatform) async throws {
        let app = RNApp(platform)
        try await app.open("drawer-test")

        let result = try await app.offsider("tap --id drawer-test-slow-push --verify")

        #expect(result.exitCode == 0, "\(result.stderr)")
        #expect(result.stderr.contains("watching instead of tapping again"), "\(result.stderr)")
        _ = try await app.waitForNode { $0["id"] as? String == "drawer-test-slow-title" }
        #expect(try await app.label(of: "drawer-test-slow-presses") == "Slow Presses: 1", "\(result.stderr)")
    }

    @Test("tap Back with --verify-id for the page beneath verifies once that page is in front", arguments: RNPlatform.enabled)
    func verifyIDForPageBeneath(platform: RNPlatform) async throws {
        let app = RNApp(platform)
        try await app.open("cover-test")
        try await app.run("tap --id cover-test-open-details")
        try await app.run("tap --id cover-test-open-notes")
        _ = try await app.waitForNode { $0["id"] as? String == "cover-test-notes-title" }

        let result = try await app.run("tap --id cover-test-notes-back --verify-id cover-test-details-title --json")

        let report = try #require(try JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any], "\(result.stdout)")
        #expect(report["verified"] as? Bool == true, "\(result.stdout)")
        #expect(report["change"] as? String == "element", "\(result.stdout)")
        try await app.run("wait --id cover-test-notes-title --gone --timeout 5")
    }

    @Test("--verify-id for a button that stays under the pushed page names the page over it and that nothing changed", arguments: RNPlatform.enabled)
    func verifyIDStillBeneath(platform: RNPlatform) async throws {
        let app = RNApp(platform)
        try await app.open("cover-test")
        try await app.run("tap --id cover-test-open-details")
        _ = try await app.waitForNode { $0["id"] as? String == "cover-test-details-title" }

        let result = try await app.offsider("tap --id cover-test-details-title --verify-id cover-test-open-details --verify-timeout 1 --json")

        #expect(result.exitCode == 5, "\(result.stderr)")
        #expect(result.stderr.contains(#"it is under group "cover-test-details""#), "\(result.stderr)")
        let report = try #require(try JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any], "\(result.stdout)")
        #expect(report["note"] as? String == "screen_unchanged", "\(result.stdout)")
    }
}
