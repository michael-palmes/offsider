import Foundation
import Testing

/// `--verify` on a phone's live ticker: the slow reads and capture of a USB phone, where a ticker most often outruns the check.
@Suite("Android phone verify", .serialized, .enabled(if: isAndroidPhoneE2EEnabled))
struct AndroidPhoneVerifyTests {
    static func openAndRead() async throws {
        try await AndroidE2E.open("live-ticker", waitingFor: "live-ticker-screen")
        try await Task.sleep(for: .seconds(2))
        try await AndroidE2E.run("describe-ui")
        try await Task.sleep(for: .milliseconds(1200))
    }

    static func report(_ output: SeparatedCommandOutput) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: Data(output.stdout.utf8)) as? [String: Any])
    }

    @Test("a toggle verifies on its first attempt without a baseline capture, and reports its phases")
    func toggle() async throws {
        try await AndroidE2E.onAwakePhone {
            try await Self.openAndRead()
            let result = try await AndroidE2E.offsider("tap --id live-ticker-toggle --verify --json", environment: ["OFFSIDER_TIMINGS": "1"])
            let report = try Self.report(result)

            #expect(result.exitCode == 0, "\(result.stderr)")
            #expect(report["attempts"] as? Int == 1)
            let changes = (report["changes"] as? [[String: Any]] ?? []).compactMap { $0["node"] as? String }
            #expect(!changes.contains { $0.contains("live-ticker-heart-rate") || $0.contains("live-ticker-steps") }, "\(changes)")
            #expect(!AndroidE2E.timingPhases(result.stderr).contains("baseline-capture"))
            #expect(Set(((report["phasesMs"] as? [String: Any]) ?? [:]).keys) == ["settle", "resolve", "baseline", "dispatch", "verify"])
            try await AndroidE2E.run("tap --id live-ticker-toggle")
        }
    }

    @Test("a tap that changes nothing is unverified after one attempt, naming the ticking heart rate as live")
    func noOp() async throws {
        try await AndroidE2E.onAwakePhone {
            try await Self.openAndRead()
            let result = try await AndroidE2E.offsider("tap --id live-ticker-noop --verify --json")
            let report = try Self.report(result)

            #expect(result.exitCode == 5, "\(result.stderr)")
            #expect(report["attempts"] as? Int == 1)
            let live = (report["ignored"] as? [[String: Any]] ?? []).filter { $0["reason"] as? String == "live" }.compactMap { $0["node"] as? String }
            #expect(live.contains("live-ticker-heart-rate"), "\(live)")
        }
    }

    @Test("a verified tap on a static screen captures its baseline alongside its reads")
    func baselineAlongsideReads() async throws {
        try await AndroidE2E.onAwakePhone {
            try await AndroidE2E.open("tap-test", waitingFor: "tap-test-area")
            let result = try await AndroidE2E.offsider("tap --id tap-test-area --verify", environment: ["OFFSIDER_TIMINGS": "1"])

            #expect(result.exitCode == 0, "\(result.stderr)")
            let phases = AndroidE2E.timingPhases(result.stderr)
            #expect(phases.contains("baseline-capture") && phases.contains("dispatch") && phases.contains("verify-poll"), "\(phases)")
            _ = try await AndroidE2E.waitForLabel(of: "tap-count") { $0 == "Tap Count: 1" }
        }
    }
}
