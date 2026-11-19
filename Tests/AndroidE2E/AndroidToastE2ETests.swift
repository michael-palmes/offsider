import Foundation
import Testing

/// The alert-test screen's "Show toast" raises an Android toast and changes nothing else on screen.
@Suite("Android toasts", .serialized, .enabled(if: isAndroidE2EEnabled))
struct AndroidToastE2ETests {
    static let package = "com.mpalmes.offsider.playground.rn"

    static func toasts() async throws -> [[String: Any]] {
        let tree = try await AndroidE2E.tree()
        let context = try #require(tree["context"] as? [String: Any])
        return try #require(context["toasts"] as? [[String: Any]], "describe-ui listed no toasts key: \(context)")
    }

    static func texts(_ toasts: [[String: Any]]) -> [String] {
        toasts.compactMap { $0["text"] as? String }
    }

    @Test("a tap whose only effect is a toast verifies as a toast, describe-ui lists it for the app, and wait --toast meets it")
    func toastIsSeen() async throws {
        try await AndroidE2E.open("alert-test", waitingFor: "alert-test-show-toast")
        let tap = try await AndroidE2E.run("tap --id alert-test-show-toast --verify")
        #expect(tap.stdout.contains(#"verified: a toast "Draft saved" showed"#), "stdout: \(tap.stdout)")

        let listed = try await Self.toasts()
        #expect(Self.texts(listed).last == "Draft saved")
        #expect(listed.allSatisfy { $0["package"] as? String == Self.package })
        #expect(listed.allSatisfy { (($0["ageMs"] as? NSNumber)?.intValue ?? .max) < 30_000 })

        let met = try await AndroidE2E.offsider("wait --toast 'Draft saved' --timeout 3")
        #expect(met.exitCode == 0, "stderr: \(met.stderr)")
        let missed = try await AndroidE2E.offsider("wait --toast 'Never shown' --timeout 1")
        #expect(missed.exitCode == 5)
        #expect(!missed.stderr.contains("Draft saved") && !missed.stdout.contains("Draft saved"))
    }

    @Test("with the launcher in front the helper lists none of the app's toasts, and lists them again once the app is back")
    func otherAppSeesNone() async throws {
        try await AndroidE2E.open("alert-test", waitingFor: "alert-test-show-toast")
        try await AndroidE2E.run("tap --id alert-test-show-toast")
        try await AndroidE2E.run("button home")
        _ = try await AndroidE2E.offsider("wait --settled --timeout 5")
        #expect(try await Self.toasts().isEmpty)

        try await AndroidE2E.shell("am start -W -a android.intent.action.VIEW -d offsiderplaygroundrn://screen/alert-test \(Self.package)")
        _ = try await AndroidE2E.waitForNode(timeout: 20) { $0["id"] as? String == "alert-test-show-toast" }
        #expect(Self.texts(try await Self.toasts()).contains("Draft saved"))
    }

    @Test("a toast that has left the screen is still listed with its age, never meets wait --toast, and goes after 30 s")
    func oldToastsGo() async throws {
        try await AndroidE2E.open("alert-test", waitingFor: "alert-test-show-toast")
        try await AndroidE2E.run("tap --id alert-test-show-toast")
        try await Task.sleep(for: .seconds(5))
        let listed = try await Self.toasts()
        #expect(Self.texts(listed).contains("Draft saved"))
        #expect(listed.allSatisfy { (($0["ageMs"] as? NSNumber)?.intValue ?? 0) > 3_500 })
        let summary = try await AndroidE2E.run("describe-ui --summary")
        #expect(summary.stdout.contains("off screen by now"), "stdout: \(summary.stdout)")
        let old = try await AndroidE2E.offsider("wait --toast 'Draft saved' --timeout 1")
        #expect(old.exitCode == 5, "stdout: \(old.stdout)")
        #expect(old.stdout.contains("from before the wait began") || old.stderr.contains("from before the wait began"))
        try await Task.sleep(for: .seconds(26))
        #expect(try await Self.toasts().isEmpty)
    }

    @Test("with one helper per command, as on a phone, a later describe-ui sees no toast an earlier command raised")
    func perCommandHelperSeesOnlyItsOwn() async throws {
        let perCommand = ["OFFSIDER_ANDROID_SESSION": "off"]
        try await AndroidE2E.run("session stop")
        try await AndroidE2E.open("alert-test", waitingFor: "alert-test-show-toast")
        try await AndroidE2E.run("session stop")
        let tap = try await AndroidE2E.run("tap --id alert-test-show-toast --verify", environment: perCommand)
        #expect(tap.stdout.contains(#"a toast "Draft saved" showed"#), "stdout: \(tap.stdout)")
        let later = try await AndroidE2E.run("describe-ui", environment: perCommand)
        let context = try #require((try JSONSerialization.jsonObject(with: Data(later.stdout.utf8)) as? [String: Any])?["context"] as? [String: Any])
        #expect((context["toasts"] as? [Any])?.isEmpty == true)
    }
}
