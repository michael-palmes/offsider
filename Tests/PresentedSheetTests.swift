import Foundation
import Testing

@Suite("Presented by another process", .serialized, .enabled(if: isE2EEnabled))
struct PresentedSheetTests {
    /// Opens the photo picker, which the system draws in its own process over the fixture screen, and returns the first summary that names it.
    static func openPicker(simulatorUDID: String) async throws -> String {
        try await TestHelpers.launchPlaygroundApp(to: "presented-sheet-test", simulatorUDID: simulatorUDID)
        try await TestHelpers.runOffsiderCommand("tap --id presented-sheet-test-open", simulatorUDID: simulatorUDID)
        let deadline = Date().addingTimeInterval(20)
        var summary = ""
        while Date() < deadline {
            summary = try await TestHelpers.runOffsiderCommandSeparated("describe-ui --summary", simulatorUDID: simulatorUDID).stdout
            if summary.contains("\n# presented: ") { return summary }
            try await Task.sleep(for: .milliseconds(500))
        }
        Issue.record("the picker was never named as presented: \(summary)")
        return summary
    }

    @Test("describe-ui names the picker another process draws, by its executable's file name, while the tree still lists the screen beneath")
    func describeNamesPicker() async throws {
        let simulatorUDID = try TestHelpers.requireSimulatorUDID()
        let summary = try await Self.openPicker(simulatorUDID: simulatorUDID)

        let json = try await TestHelpers.runOffsiderCommandSeparated("describe-ui", simulatorUDID: simulatorUDID)
        let object = try #require(try JSONSerialization.jsonObject(with: Data(json.stdout.utf8)) as? [String: Any])
        let presented = try #require((object["context"] as? [String: Any])?["presented"] as? [String: Any], "\(object["context"] ?? "no context")")
        let process = try #require(presented["process"] as? String)

        #expect(summary.contains("presented-sheet-test-open"), "the app's own tree still lists the screen beneath")
        #expect(!process.isEmpty && !process.contains("/"))
        #expect(!process.contains("OffsiderPlayground"))
    }

    @Test("a wait for the screen beneath to go passes and names what covers it, and with --allow-offscreen misses and names what is presented")
    func waitGoneUnderPicker() async throws {
        let simulatorUDID = try TestHelpers.requireSimulatorUDID()
        _ = try await Self.openPicker(simulatorUDID: simulatorUDID)

        let gone = try await TestHelpers.runOffsiderCommandSeparated("wait --id presented-sheet-test-open --gone --timeout 10 --json", simulatorUDID: simulatorUDID)
        #expect(gone.exitCode == 0, "\(gone.stderr)")
        let object = try #require((try? JSONSerialization.jsonObject(with: Data(gone.stdout.utf8))) as? [String: Any], "\(gone.stdout) \(gone.stderr)")
        #expect(object["met"] as? Bool == true)
        #expect((object["reason"] as? String)?.contains(": under ") == true, "\(object["reason"] ?? "no reason")")

        let held = try await TestHelpers.runOffsiderCommandSeparated("wait --id presented-sheet-test-open --gone --allow-offscreen --timeout 1", simulatorUDID: simulatorUDID)
        #expect(held.exitCode == 5)
        #expect(held.stderr.contains("; presented: "), "\(held.stderr)")
    }
}
