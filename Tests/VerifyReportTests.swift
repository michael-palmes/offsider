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
        let report = VerifyReport(command: "key", target: "keycode 40", dispatched: .yes, verified: true, attempts: 1, change: .accessibilityTree)
        let json = try object(report)
        #expect(Set(json.keys) == [
            "version", "command", "target", "dispatched", "verified", "attempts", "change", "changes", "changesTruncated", "ignored", "note", "style",
            "elapsedMs", "phasesMs", "exitCode", "error",
        ])
        #expect((json["ignored"] as? [Any])?.isEmpty == true)
        #expect((json["changes"] as? [Any])?.isEmpty == true)
        #expect(json["changesTruncated"] as? Int == 0)
        #expect(json["note"] is NSNull)
        #expect(json["version"] as? Int == 2)
        #expect(json["dispatched"] as? String == "yes")
        #expect(json["exitCode"] as? Int == 0)
        #expect(json["style"] is NSNull)
        #expect(json["error"] is NSNull)
        #expect(json["change"] as? String == "accessibility-tree")
    }

    @Test("Ignored elements, elapsed time and phases are reported in whole milliseconds, phases in their documented order")
    func timingAndIgnored() throws {
        let report = VerifyReport(
            command: "tap", target: "id=noop", dispatched: .yes, verified: false, attempts: 1, change: .none,
            ignored: [VerifyIgnored(node: "live-ticker-heart-rate", reason: .live), VerifyIgnored(node: "LogBox toast", reason: .toast)],
            elapsed: 2.3456,
            phases: VerifyPhases(settle: 0.4, resolve: 0.61, baseline: 0.05, dispatch: 0.1004, verify: 1.2)
        )
        let text = String(decoding: try report.jsonData(), as: UTF8.self)
        let json = try object(report)
        #expect(json["ignored"] as? [[String: String]] == [["node": "live-ticker-heart-rate", "reason": "live"], ["node": "LogBox toast", "reason": "toast"]])
        #expect(json["elapsedMs"] as? Int == 2346)
        let phases = try #require(json["phasesMs"] as? [String: Int])
        #expect(phases == ["settle": 400, "resolve": 610, "baseline": 50, "dispatch": 100, "verify": 1200])
        let order = ["settle", "resolve", "baseline", "dispatch", "verify"].compactMap { text.range(of: "\"\($0)\"")?.lowerBound }
        #expect(order == order.sorted() && order.count == 5)
        #expect(report.exitCode == .unverified)
    }

    @Test("The human timing suffix folds everything before the input into settle and names the input after the command")
    func timingSuffix() {
        let phases = VerifyPhases(settle: 0.2, resolve: 0.15, baseline: 0.04, dispatch: 0.12, verify: 1.23)
        #expect(phases.suffix(input: "tap") == "(settle 0.4 s, tap 0.1 s, verify 1.2 s)")
        #expect(VerifyPhases().suffix(input: "key") == "(settle 0.0 s, key 0.0 s, verify 0.0 s)")
    }

    @Test("A --verify-id report says change element; a refusal before input is dispatched no with verify_target_present, exit 1")
    func elementChange() throws {
        let verified = VerifyReport(command: "tap", target: "id=next", dispatched: .yes, verified: true, attempts: 1, change: .element)
        #expect(try object(verified)["change"] as? String == "element")
        #expect(verified.exitCode == .success)
        #expect(FailureReason.verifyTargetPresent.exitCode == .failure)
    }

    @Test("A tap report carries its final style as a lowercase string")
    func tapStyle() throws {
        let report = VerifyReport(command: "tap", target: "(200, 400)", dispatched: .yes, verified: false, attempts: 2, change: .none, style: .physical)
        let json = try object(report)
        #expect(json["style"] as? String == "physical")
        #expect(json["change"] as? String == "none")
        #expect(json["exitCode"] as? Int == 5)
    }

    @Test("Exit codes: verified 0, dispatched but unverified 5, a failure takes its reason's code")
    func exitCodes() {
        let verified = VerifyReport(command: "tap", target: "t", dispatched: .yes, verified: true, attempts: 1, change: .screenshot)
        let unverified = VerifyReport(command: "tap", target: "t", dispatched: .yes, verified: false, attempts: 2, change: .none)
        let notBooted = ErrorPayload(reason: .deviceNotBooted, message: "not booted", dispatched: .no)
        let lost = ErrorPayload(reason: .inputFailed, message: "lost", dispatched: .unknown)
        let missing = ErrorPayload(reason: .selectorNotFound, message: "missing", dispatched: .no)
        let failed = VerifyReport(command: "tap", target: "t", dispatched: .no, verified: false, attempts: 0, change: .none, error: notBooted)
        let failedMidSend = VerifyReport(command: "type", target: "t", dispatched: .unknown, verified: false, attempts: 1, change: .none, error: lost)
        let notFound = VerifyReport(command: "tap", target: "id=x", dispatched: .no, verified: false, attempts: 0, change: .none, error: missing)
        #expect(verified.exitCode.rawValue == 0)
        #expect(unverified.exitCode.rawValue == 5)
        #expect(failed.exitCode.rawValue == 7)
        #expect(failedMidSend.exitCode.rawValue == 1)
        #expect(notFound.exitCode.rawValue == 2)
    }

    @Test("A verify failure report carries reason, hint, candidates and exit code, in key order")
    func failureReport() throws {
        let candidate = FailureCandidate(id: "save", label: "Save", role: "button", frame: UIFrame(x: 16, y: 700, width: 160, height: 44), onScreen: true)
        let error = ErrorPayload(
            reason: .selectorAmbiguous,
            message: "Multiple (2) accessibility elements matched --id 'save'",
            hint: "offsider describe-ui --device D --summary",
            dispatched: .no,
            candidates: [candidate, candidate]
        )
        let report = VerifyReport(command: "tap", target: "id=save", dispatched: .no, verified: false, attempts: 0, change: .none, error: error)
        let text = String(decoding: try report.jsonData(), as: UTF8.self)
        let keys = ["\"version\"", "\"command\"", "\"target\"", "\"dispatched\"", "\"verified\"", "\"attempts\"", "\"change\"", "\"style\"", "\"exitCode\"", "\"error\""]
        let positions = keys.compactMap { text.range(of: $0)?.lowerBound }
        #expect(positions.count == keys.count)
        #expect(positions == positions.sorted())

        let json = try object(report)
        #expect(json["exitCode"] as? Int == 6)
        let payload = try #require(json["error"] as? [String: Any])
        #expect(Set(payload.keys) == ["reason", "message", "hint", "dispatched", "candidates"])
        #expect(payload["reason"] as? String == "selector_ambiguous")
        #expect(payload["hint"] as? String == "offsider describe-ui --device D --summary")
        #expect(payload["dispatched"] as? String == "no")
        let candidates = try #require(payload["candidates"] as? [[String: Any]])
        #expect(candidates.count == 2)
        #expect(Set(candidates[0].keys) == ["id", "label", "role", "frame", "onScreen", "index", "window", "screen", "beneath"])
        #expect(candidates[0]["label"] as? String == "Save")
        #expect(candidates[0]["onScreen"] as? Bool == true)
    }
}
