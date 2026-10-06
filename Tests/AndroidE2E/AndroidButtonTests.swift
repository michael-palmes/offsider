import Foundation
import Testing

@Suite("Android button", .serialized, .enabled(if: isAndroidE2EEnabled))
struct AndroidButtonTests {
    private func focusedWindow() async throws -> String {
        try await AndroidE2E.shell("dumpsys window | grep -m1 mCurrentFocus")
    }

    private func wakefulness() async throws -> String {
        try await AndroidE2E.shell("dumpsys power | grep -m1 mWakefulness=").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The newest line of AudioService's volume event log.
    private func lastVolumeEvent() async throws -> String {
        let log = try await AndroidE2E.shell("dumpsys audio | sed -n '/Events log: volume changes/,/^$/p' | grep adjustSuggestedStreamVolume | tail -1")
        return log.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func waitFor(_ description: String, timeout: TimeInterval = 10, _ check: () async throws -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if try await check() { return }
            try await Task.sleep(for: .milliseconds(300))
        }
        Issue.record("timed out waiting for \(description)")
    }

    @Test("back pops the React Navigation stack")
    func back() async throws {
        try await AndroidE2E.open("tap-test", waitingFor: "tap-test-area")
        try await AndroidE2E.run("button back")
        _ = try await AndroidE2E.waitForNode { $0["id"] as? String == "menu-title" }
    }

    @Test("home --verify --json confirms the launcher came to the front")
    func homeVerified() async throws {
        try await AndroidE2E.open("tap-test", waitingFor: "tap-test-area")
        let result = try await AndroidE2E.run("button home --verify --json")
        let report = try #require(try JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any])
        #expect(report["verified"] as? Bool == true)
        #expect(report["change"] as? String == "activity")
        #expect(try await focusedWindow().contains("Launcher"))
    }

    @Test("home shows the launcher")
    func home() async throws {
        try await AndroidE2E.open("tap-test", waitingFor: "tap-test-area")
        try await AndroidE2E.run("button home")
        try await waitFor("the launcher") { try await focusedWindow().contains("Launcher") }
    }

    @Test("app-switch opens Recents")
    func appSwitch() async throws {
        try await AndroidE2E.open("tap-test", waitingFor: "tap-test-area")
        try await AndroidE2E.run("button app-switch")
        _ = try await AndroidE2E.waitForNode { ($0["id"] as? String)?.hasSuffix(":id/overview_panel") == true }
        try await AndroidE2E.run("button home")
    }

    @Test("volume-up and volume-down reach AudioService as volume keys", arguments: [("volume-up", "ADJUST_RAISE"), ("volume-down", "ADJUST_LOWER")])
    func volume(button: String, direction: String) async throws {
        let before = try await lastVolumeEvent()
        try await AndroidE2E.run("button \(button)")
        try await waitFor("a \(direction) volume event") {
            let now = try await lastVolumeEvent()
            return now != before && now.contains("dir:\(direction)")
        }
    }

    @Test("lock turns the display off and a second lock wakes it")
    func lock() async throws {
        try await AndroidE2E.run("button lock")
        try await waitFor("sleep") {
            let state = try await wakefulness()
            return state.contains("Asleep") || state.contains("Dozing")
        }
        try await AndroidE2E.run("button lock")
        try await waitFor("wake") { try await wakefulness().contains("Awake") }
    }

    @Test("iOS-only buttons are usage errors on Android", arguments: ["apple-pay", "side-button", "siri"])
    func iosOnly(button: String) async throws {
        let result = try await AndroidE2E.offsider("button \(button)")
        #expect(result.exitCode == 64)
        #expect(result.stderr.contains("The \(button) button is iOS only"))
    }
}
