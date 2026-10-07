import Foundation
import Testing

/// `--verify` and `wait --settled` on the live ticker: a price that ticks every second, a toggle and a push delayed 1.2 s.
@Suite("React Native live values", .serialized, .enabled(if: RNPlatform.anyEnabled))
struct ReactNativeLiveTests {
    /// Opens the ticker and reads it 2 s after the last input, then lets it tick, so the next command learns the price as live.
    static func openAndRead(_ app: RNApp) async throws {
        try await app.open("live-ticker")
        try await Task.sleep(for: .seconds(2))
        try await app.run("describe-ui")
        try await Task.sleep(for: .milliseconds(1200))
    }

    static func report(_ output: SeparatedCommandOutput) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: Data(output.stdout.utf8)) as? [String: Any])
    }

    static func changedNodes(_ report: [String: Any]) -> [String] {
        (report["changes"] as? [[String: Any]] ?? []).compactMap { $0["node"] as? String }
    }

    @Test("a toggle verifies on its first attempt, its changes leave the ticking price out, and the line ends with its timing", arguments: RNPlatform.enabled)
    func toggleVerifies(platform: RNPlatform) async throws {
        let app = RNApp(platform)
        try await Self.openAndRead(app)

        let result = try await app.offsider("tap --id live-ticker-toggle --verify --json")
        let report = try Self.report(result)

        #expect(result.exitCode == 0, "\(result.stderr)")
        #expect(report["attempts"] as? Int == 1)
        #expect(!Self.changedNodes(report).contains { $0.contains("live-ticker-price") }, "\(Self.changedNodes(report))")
        #expect(Self.changedNodes(report).contains { $0.contains("live-ticker-toggle") }, "\(Self.changedNodes(report))")
        #expect(report["phasesMs"] is [String: Any] && report["elapsedMs"] is Int)
        #expect(result.stderr.contains(#/verified: .*attempt 1 of 2.* \(settle [0-9.]+ s, tap [0-9.]+ s, verify [0-9.]+ s\)/#), "\(result.stderr)")
        try await app.run("tap --id live-ticker-toggle")
    }

    @Test("a tap that changes nothing is not verified and not retried, and the price is named as live", arguments: RNPlatform.enabled)
    func noOpNotVerified(platform: RNPlatform) async throws {
        let app = RNApp(platform)
        try await Self.openAndRead(app)

        let result = try await app.offsider("tap --id live-ticker-noop --verify --json")
        let report = try Self.report(result)

        #expect(result.exitCode == 5, "\(result.stderr)")
        #expect(report["attempts"] as? Int == 1)
        let ignored = (report["ignored"] as? [[String: Any]] ?? []).filter { $0["reason"] as? String == "live" }.compactMap { $0["node"] as? String }
        #expect(ignored.contains("live-ticker-price"), "\(report["ignored"] ?? "none")")
        #expect(result.stderr.contains("Ignored live:"), "\(result.stderr)")
    }

    @Test("a push that lands after a short --verify-timeout still verifies on the first attempt, and is pushed once", arguments: RNPlatform.enabled)
    func latePushVerifiesOnce(platform: RNPlatform) async throws {
        let app = RNApp(platform)
        try await Self.openAndRead(app)

        let result = try await app.offsider("tap --id live-ticker-open-detail --verify --verify-timeout 0.5 --json")
        let report = try Self.report(result)

        #expect(result.exitCode == 0, "\(result.stderr)")
        #expect(report["attempts"] as? Int == 1)
        _ = try await app.waitForNode { $0["id"] as? String == "live-ticker-detail" }
        try await app.run("tap --id live-ticker-detail-back")
        _ = try await app.waitForNode { $0["id"] as? String == "live-ticker-open-detail" }
    }

    @Test("wait --settled --ignore-values right after a tap waits for the delayed push, then for it to settle", arguments: RNPlatform.enabled)
    func settledWaitsForPush(platform: RNPlatform) async throws {
        let app = RNApp(platform)
        try await app.open("live-ticker")

        try await app.run("tap --id live-ticker-open-detail")
        let waited = try await app.offsider("wait --settled --ignore-values --timeout 10 --json")

        #expect(waited.exitCode == 0, "\(waited.stderr)")
        #expect(try await app.label(of: "live-ticker-detail") != nil, "the wait passed before the push")
        try await app.run("tap --id live-ticker-detail-back")
    }

    @Test("without --ignore-values the ticking price never lets the screen settle, and the timeout says to add it", arguments: RNPlatform.enabled)
    func tickerNeverSettles(platform: RNPlatform) async throws {
        let app = RNApp(platform)
        try await app.open("live-ticker")
        try await Task.sleep(for: .seconds(2))

        let waited = try await app.offsider("wait --settled --quiet-ms 1500 --timeout 4")

        #expect(waited.exitCode == 5)
        #expect(waited.stderr.contains("add --ignore-values"), "\(waited.stderr)")
    }
}
