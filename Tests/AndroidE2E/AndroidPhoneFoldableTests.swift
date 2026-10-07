import Foundation
import Testing

/// Captures on a foldable phone such as the Galaxy Z Fold, run once unfolded and once folded by hand.
/// On a phone with one display each test only confirms that `posture` refuses it.
@Suite("Android phone foldable", .serialized, .enabled(if: isAndroidPhoneE2EEnabled))
struct AndroidPhoneFoldableTests {
    /// The posture and the panel it shows, or nil on a phone that does not fold.
    static func panel() async throws -> (posture: String, display: String)? {
        let result = try await AndroidE2E.offsider("posture --json")
        guard result.exitCode == 0 else {
            #expect(result.stderr.contains("not a foldable device"), "\(result.stderr)")
            return nil
        }
        let object = try #require(try JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any])
        return (try #require(object["posture"] as? String), try #require(object["display"] as? String))
    }

    static func screenshotJSON(_ flags: String = "", environment: [String: String]? = nil) async throws -> [String: Any] {
        let output = AndroidE2E.temporaryFile("fold.png")
        defer { try? FileManager.default.removeItem(at: output) }
        let result = try await AndroidE2E.run("screenshot --json \(flags) --output \(AndroidE2E.quote(output.path))", environment: environment)
        return try #require(try JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any])
    }

    @Test("without --display the capture is the active panel at its logical size, and --json names the panel describe-ui and posture name")
    func activePanel() async throws {
        try await AndroidE2E.onAwakePhone {
            try await AndroidE2E.open("tap-test", waitingFor: "tap-test-area")
            guard let panel = try await Self.panel() else { return }
            let output = try await AndroidE2E.screenshot("fold.png")
            defer { try? FileManager.default.removeItem(at: output) }
            let size = try AndroidE2E.pngSize(at: output)
            let expected = try await AndroidE2E.logicalPixelSize()
            #expect(size.width == expected.width && size.height == expected.height, "PNG \(size), wm size \(expected)")

            let report = try await Self.screenshotJSON()
            let tree = try await AndroidE2E.tree()
            let treeDisplay = ((tree["screen"] as? [String: Any])?["display"] as? [String: Any])?["id"] as? String
            #expect((report["display"] as? [String: Any])?["id"] as? String == panel.display)
            #expect(treeDisplay == panel.display)
            #expect(panel.display == (panel.posture == "closed" ? "cover" : "inner"))
        }
    }

    @Test("the next command captures the cached panel without reading the displays, and with the cache off it reads them again")
    func secondCaptureUsesCache() async throws {
        try await AndroidE2E.onAwakePhone {
            try await AndroidE2E.open("tap-test", waitingFor: "tap-test-area")
            guard try await Self.panel() != nil else { return }
            _ = try await AndroidE2E.screenshot("first.png")
            let timed = ["OFFSIDER_TIMINGS": "1"]
            let second = try await AndroidE2E.run("screenshot --output \(AndroidE2E.quote(AndroidE2E.temporaryFile("second.png").path))", environment: timed)
            #expect(!AndroidE2E.timingPhases(second.stderr).contains("display-status"), "\(AndroidE2E.timingPhases(second.stderr))")
            let off = try await AndroidE2E.run(
                "screenshot --output \(AndroidE2E.quote(AndroidE2E.temporaryFile("off.png").path))",
                environment: timed.merging(["OFFSIDER_DISPLAY_CACHE": "off"]) { $1 }
            )
            #expect(AndroidE2E.timingPhases(off.stderr).contains("display-status"), "\(AndroidE2E.timingPhases(off.stderr))")
        }
    }

    @Test("--mask-secure and --compare work without --display, and --display main is refused")
    func maskCompareAndMain() async throws {
        try await AndroidE2E.onAwakePhone {
            try await AndroidE2E.open("tap-test", waitingFor: "tap-test-area")
            guard try await Self.panel() != nil else { return }
            let expected = try await AndroidE2E.logicalPixelSize()
            let masked = try await Self.screenshotJSON("--mask-secure")
            #expect(masked["width"] as? Int == expected.width && masked["height"] as? Int == expected.height)

            let baseline = try await AndroidE2E.screenshot("baseline.png")
            defer { try? FileManager.default.removeItem(at: baseline) }
            let compared = try await AndroidE2E.offsider("screenshot --compare \(AndroidE2E.quote(baseline.path))")
            #expect(compared.exitCode == 5, "a still screen compared with itself: \(compared.stdout)\(compared.stderr)")

            let main = try await AndroidE2E.offsider("screenshot --display main --output \(AndroidE2E.quote(AndroidE2E.temporaryFile("main.png").path))")
            #expect(main.exitCode == 64, "\(main.stderr)")
        }
    }
}
