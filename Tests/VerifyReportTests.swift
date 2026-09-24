import Foundation
import Testing
import OffsiderCore

@Suite("Verify Report Tests")
struct VerifyReportTests {
    private func object(_ report: VerifyReport) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: report.jsonData()) as? [String: Any])
    }

    @Test("The JSON has exactly the documented keys, with null style and error for key")
    func jsonKeys() throws {
        let report = VerifyReport(command: "key", target: "keycode 40", dispatched: true, verified: true, attempts: 1, change: .accessibilityTree)
        let json = try object(report)
        #expect(Set(json.keys) == ["version", "command", "target", "dispatched", "verified", "attempts", "change", "style", "error"])
        #expect(json["version"] as? Int == 1)
        #expect(json["style"] is NSNull)
        #expect(json["error"] is NSNull)
        #expect(json["change"] as? String == "accessibility-tree")
    }

    @Test("A tap report carries its final style as a lowercase string")
    func tapStyle() throws {
        let report = VerifyReport(command: "tap", target: "(200, 400)", dispatched: true, verified: false, attempts: 2, change: .none, style: .physical)
        let json = try object(report)
        #expect(json["style"] as? String == "physical")
        #expect(json["change"] as? String == "none")
    }

    @Test("Exit codes: verified 0, dispatched but unverified 5, error 1")
    func exitCodes() {
        let verified = VerifyReport(command: "tap", target: "t", dispatched: true, verified: true, attempts: 1, change: .screenshot)
        let unverified = VerifyReport(command: "tap", target: "t", dispatched: true, verified: false, attempts: 2, change: .none)
        let failed = VerifyReport(command: "tap", target: "t", dispatched: false, verified: false, attempts: 0, change: .none, error: "not booted")
        let failedAfterDispatch = VerifyReport(command: "type", target: "t", dispatched: true, verified: false, attempts: 1, change: .none, error: "lost")
        #expect(verified.exitCode.rawValue == 0)
        #expect(unverified.exitCode.rawValue == 5)
        #expect(failed.exitCode.rawValue == 1)
        #expect(failedAfterDispatch.exitCode.rawValue == 1)
    }
}
