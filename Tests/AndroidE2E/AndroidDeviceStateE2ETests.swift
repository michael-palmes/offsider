import Foundation
import Testing

@Suite("Android device state", .serialized, .enabled(if: isAndroidE2EEnabled))
struct AndroidDeviceStateE2ETests {
    static let app = "--app \(AndroidE2E.package)"

    /// Runs `body`, then `cleanup` whether or not it threw, so a failed run leaves the emulator as it was.
    static func restoring(_ cleanup: () async -> Void, _ body: () async throws -> Void) async throws {
        do {
            try await body()
        } catch {
            await cleanup()
            throw error
        }
        await cleanup()
    }

    /// Android 9 drops a runtime permission's line once it holds no grant and no flags, so there a missing line reads as denied with none.
    static func runtimeState(_ permission: String) async throws -> String {
        let dump = try await AndroidE2E.shell("dumpsys package \(AndroidE2E.package)")
        let line = dump.split(whereSeparator: \.isNewline).first { $0.contains("android.permission.\(permission): granted=") }.map(String.init)
        if line == nil, try await AndroidE2E.apiLevel() < 29 { return "android.permission.\(permission): granted=false" }
        return line ?? ""
    }

    @Test("granting camera shows granted on the permission-state screen, and reset denies it with the user flags cleared")
    func cameraPermission() async throws {
        try await AndroidE2E.ensurePlaygroundInstalled()
        // POST_NOTIFICATIONS is a runtime permission only from Android 13 (API 33).
        let services = try await AndroidE2E.apiLevel() >= 33 ? "camera notifications" : "camera"
        try await AndroidE2E.run("permission reset \(services) \(Self.app)")
        try await Self.restoring({ _ = try? await AndroidE2E.offsider("permission reset \(services) \(Self.app)") }) {
            let grant = try await AndroidE2E.run("permission grant camera \(Self.app) --json")
            #expect(grant.stdout.contains(#""name":"android.permission.CAMERA","previous":"denied","current":"granted","changed":true"#))
            try await AndroidE2E.open("permission-state", waitingFor: "permission-state-camera")
            #expect(try await AndroidE2E.waitForLabel(of: "permission-state-camera") { $0 == "Camera: granted" } == "Camera: granted")
            #expect(try await AndroidE2E.label(of: "permission-state-notifications") == "Notifications: denied")

            let again = try await AndroidE2E.run("permission grant camera \(Self.app)")
            #expect(again.stdout.contains("was already granted"))

            try await AndroidE2E.run("permission revoke camera \(Self.app)")
            #expect(try await Self.runtimeState("CAMERA").contains("granted=false"))
            try await AndroidE2E.run("permission grant camera \(Self.app)")
            let reset = try await AndroidE2E.run("permission reset camera \(Self.app)")
            #expect(reset.stdout.contains("it asks again on next use"))
            let line = try await Self.runtimeState("CAMERA")
            #expect(line.contains("granted=false"))
            #expect(!line.contains("USER_SET") && !line.contains("USER_FIXED"))

            try await AndroidE2E.open("permission-state", waitingFor: "permission-state-camera")
            #expect(try await AndroidE2E.waitForLabel(of: "permission-state-camera") { $0 == "Camera: denied" } == "Camera: denied")
        }
    }

    /// Polls `alert show --json` until the app's permission dialog is up; the parsed report.
    static func waitForPrompt(timeout: TimeInterval = 15) async throws -> [String: Any] {
        let deadline = Date().addingTimeInterval(timeout)
        var last = ""
        while Date() < deadline {
            let shown = try await AndroidE2E.offsider("alert show \(app) --json")
            if shown.exitCode == 0, let report = try JSONSerialization.jsonObject(with: Data(shown.stdout.utf8)) as? [String: Any] { return report }
            last = shown.stderr
            try await Task.sleep(for: .milliseconds(400))
        }
        throw AndroidE2EError(description: "No permission dialog for the playground showed within \(Int(timeout)) s: \(last)")
    }

    static func roles(_ report: [String: Any]) -> [String] {
        let prompt = report["prompt"] as? [String: Any]
        return (prompt?["buttons"] as? [[String: Any]] ?? []).compactMap { $0["role"] as? String }
    }

    @Test("alert reads the camera dialog the playground raised, refuses it to another app, denies it, then accepts it with the grant that lasts, and reset makes the app ask again")
    func alertAnswersTheCameraDialog() async throws {
        try await AndroidE2E.ensurePlaygroundInstalled()
        try await AndroidE2E.run("permission reset camera \(Self.app)")
        try await Self.restoring({ _ = try? await AndroidE2E.offsider("permission reset camera \(Self.app)") }) {
            try await AndroidE2E.open("permission-state", waitingFor: "permission-state-request-camera")
            let none = try await AndroidE2E.offsider("alert show \(Self.app) --json")
            #expect(none.exitCode == 2, "\(none.stderr)")
            #expect(none.stdout.contains(#""reason":"alert_not_shown""#))

            try await AndroidE2E.run("tap --id permission-state-request-camera")
            let shown = try await Self.waitForPrompt()
            #expect(Self.roles(shown).filter { $0 == "accept" }.count == 1)
            #expect(Self.roles(shown).filter { $0 == "deny" }.count == 1)
            #expect(shown["app"] as? String == AndroidE2E.package)

            let other = try await AndroidE2E.offsider("alert accept --app com.example.other --json")
            #expect(other.exitCode == 7, "\(other.stderr)")
            #expect(other.stdout.contains(#""reason":"system_prompt_in_front""#))
            #expect(other.stdout.contains(#""dispatched":"no""#) || !other.stdout.contains(#""dispatched":"yes""#))
            #expect(try await Self.runtimeState("CAMERA").contains("granted=false"))

            try await AndroidE2E.run("alert deny \(Self.app)")
            #expect(try await AndroidE2E.waitForLabel(of: "permission-state-camera") { $0 == "Camera: denied" } == "Camera: denied")
            #expect(try await Self.runtimeState("CAMERA").contains("granted=false"))

            // Android asks once more after one refusal.
            try await AndroidE2E.run("tap --id permission-state-request-camera")
            _ = try await Self.waitForPrompt()
            let accepted = try await AndroidE2E.run("alert accept \(Self.app) --json")
            #expect(accepted.stdout.contains(#""action":"accept""#))
            #expect(try await AndroidE2E.waitForLabel(of: "permission-state-camera") { $0 == "Camera: granted" } == "Camera: granted")
            let granted = try await Self.runtimeState("CAMERA")
            #expect(granted.contains("granted=true"))
            // A one-time grant carries this flag; the lasting one accept picks does not.
            #expect(!granted.contains("ONE_TIME"))

            let reset = try await AndroidE2E.run("permission reset camera \(Self.app)")
            #expect(reset.stdout.contains("it asks again on next use"))
            #expect(try await Self.runtimeState("CAMERA").contains("granted=false"))
        }
    }

    @Test("choose picks the one-time grant by its text, and a text no button has sends nothing")
    func alertChoosesByLabel() async throws {
        try await AndroidE2E.ensurePlaygroundInstalled()
        // The one-time button came with Android 11.
        guard try await AndroidE2E.apiLevel() >= 30 else { return }
        try await AndroidE2E.run("permission reset camera \(Self.app)")
        try await Self.restoring({ _ = try? await AndroidE2E.offsider("permission reset camera \(Self.app)") }) {
            try await AndroidE2E.open("permission-state", waitingFor: "permission-state-request-camera")
            try await AndroidE2E.run("tap --id permission-state-request-camera")
            let shown = try await Self.waitForPrompt()
            let buttons = ((shown["prompt"] as? [String: Any])?["buttons"] as? [[String: Any]]) ?? []
            let oneTime = try #require(buttons.first { $0["role"] as? String == "other" }?["label"] as? String)

            let unknown = try await AndroidE2E.offsider("alert choose \(AndroidE2E.quote("No such button")) \(Self.app) --json")
            #expect(unknown.exitCode == 2, "\(unknown.stderr)")
            #expect(try await Self.runtimeState("CAMERA").contains("granted=false"))

            try await AndroidE2E.run("alert choose \(AndroidE2E.quote(oneTime)) \(Self.app)")
            #expect(try await AndroidE2E.waitForLabel(of: "permission-state-camera") { $0 == "Camera: granted" } == "Camera: granted")
            #expect(try await Self.runtimeState("CAMERA").contains("ONE_TIME"))
        }
    }

    @Test("an app that asks for two permissions shows them in turn, and each answer names the prompt that follows")
    func alertFollowsToTheNextPrompt() async throws {
        try await AndroidE2E.ensurePlaygroundInstalled()
        // POST_NOTIFICATIONS is a runtime permission only from Android 13 (API 33).
        guard try await AndroidE2E.apiLevel() >= 33 else { return }
        try await AndroidE2E.run("permission reset camera notifications \(Self.app)")
        try await Self.restoring({ _ = try? await AndroidE2E.offsider("permission reset camera notifications \(Self.app)") }) {
            try await AndroidE2E.open("permission-state", waitingFor: "permission-state-request-both")
            try await AndroidE2E.run("tap --id permission-state-request-both")
            _ = try await Self.waitForPrompt()
            let first = try await AndroidE2E.run("alert accept \(Self.app) --json")
            let report = try #require(try JSONSerialization.jsonObject(with: Data(first.stdout.utf8)) as? [String: Any])
            let next = try #require(report["next"] as? [String: Any], "the second permission's prompt did not follow: \(first.stdout)")
            #expect((next["buttons"] as? [[String: Any]])?.isEmpty == false)

            try await AndroidE2E.run("alert deny \(Self.app)")
            #expect(try await AndroidE2E.waitForLabel(of: "permission-state-camera") { $0 == "Camera: granted" } == "Camera: granted")
            #expect(try await AndroidE2E.waitForLabel(of: "permission-state-notifications") { $0 == "Notifications: denied" } == "Notifications: denied")
            #expect(try await Self.runtimeState("POST_NOTIFICATIONS").contains("granted=false"))
        }
    }

    @Test("a service the app does not request fails naming the manifest entry")
    func unrequestedService() async throws {
        try await AndroidE2E.ensurePlaygroundInstalled()
        let result = try await AndroidE2E.offsider("permission grant microphone \(Self.app)")
        #expect(result.exitCode == 1)
        #expect(result.stderr.contains("android.permission.RECORD_AUDIO"))
    }

    @Test("status-bar override allows and enters demo mode, and clear removes the allow setting")
    func statusBar() async throws {
        let before = try await AndroidE2E.shell("settings get global sysui_demo_allowed").trimmingCharacters(in: .whitespacesAndNewlines)
        let restore = before == "null" ? "settings delete global sysui_demo_allowed" : "settings put global sysui_demo_allowed \(before)"
        try await Self.restoring({ _ = try? await AndroidE2E.shell(restore) }) {
            let override = try await AndroidE2E.run("status-bar override --json")
            #expect(override.stdout.contains(#""previous":{"overrides":null,"demoAllowed":\#(before == "1" ? "true" : before == "0" ? "false" : "null")}"#))
            #expect(try await AndroidE2E.shell("settings get global sysui_demo_allowed").trimmingCharacters(in: .whitespacesAndNewlines) == "1")

            let clear = try await AndroidE2E.run("status-bar clear")
            #expect(clear.stdout.contains("demo mode off"))
            #expect(try await AndroidE2E.shell("settings get global sysui_demo_allowed").trimmingCharacters(in: .whitespacesAndNewlines) == "null")
        }
    }

    static func stayOnRestore() async throws -> String {
        let before = try await AndroidE2E.shell("settings get global stay_on_while_plugged_in").trimmingCharacters(in: .whitespacesAndNewlines)
        return before == "null" ? "settings delete global stay_on_while_plugged_in" : "settings put global stay_on_while_plugged_in \(before)"
    }

    @Test("stay-awake on writes every power source, takes effect only while one charges, and off clears it")
    func stayAwake() async throws {
        let restore = try await Self.stayOnRestore()
        // An emulator may report any power source, or none, so the test sets its own and resets it after.
        try await Self.restoring({ _ = try? await AndroidE2E.shell("\(restore); dumpsys battery reset") }) {
            try await AndroidE2E.shell("dumpsys battery set ac 0; dumpsys battery set usb 0; dumpsys battery set wireless 0")
            let on = try await AndroidE2E.run("stay-awake on --json")
            #expect(on.stdout.contains(#""stayAwake":true"#))
            #expect(on.stdout.contains(#""charging":[],"effective":false"#), "\(on.stdout)")
            #expect(try await AndroidE2E.shell("settings get global stay_on_while_plugged_in").trimmingCharacters(in: .whitespacesAndNewlines) == "15")

            try await AndroidE2E.shell("dumpsys battery set ac 1")
            let charging = try await AndroidE2E.run("stay-awake --json")
            #expect(charging.stdout.contains(#""charging":["ac"],"effective":true"#), "\(charging.stdout)")

            let off = try await AndroidE2E.run("stay-awake off")
            #expect(off.stdout.contains(": stay awake off (was on"))
        }
    }

    @Test("wake sends nothing to a usable emulator, and brings a sleeping one back to the app")
    func wake() async throws {
        try await AndroidE2E.open("tap-test", waitingFor: "tap-test-area")
        let idle = try await AndroidE2E.run("wake --json")
        #expect(idle.stdout.contains(#""sent":[]"#))

        try await Self.restoring({ _ = try? await AndroidE2E.shell("input keyevent KEYCODE_WAKEUP; wm dismiss-keyguard") }) {
            try await AndroidE2E.shell("input keyevent KEYCODE_SLEEP")
            let asleep = try await AndroidE2E.run("stay-awake --json")
            // With stay-awake on for AC power, the emulator dozes rather than turning the screen off.
            #expect(asleep.stdout.contains(#""current":{"screen":"off""#) || asleep.stdout.contains(#""current":{"screen":"dozing""#))

            let woken = try await AndroidE2E.run("wake --json")
            #expect(woken.stdout.contains(#""sent":["KEYCODE_WAKEUP""#))
            #expect(woken.stdout.contains(#""current":{"screen":"on","lockScreen":"hidden""#))
            try await AndroidE2E.run("assert --id tap-test-area")
        }
    }

    @Test("biometric match and no-match reach the emulator console, and enrol refuses")
    func biometric() async throws {
        let match = try await AndroidE2E.run("biometric match")
        #expect(match.stdout.contains("finger 1"))
        let noMatch = try await AndroidE2E.run("biometric no-match --json")
        #expect(noMatch.stdout.contains(#""sent":"finger touch 10""#))
        let enrol = try await AndroidE2E.offsider("biometric enrol")
        #expect(enrol.exitCode == 1)
        #expect(enrol.stderr.contains("needs a screen lock"))
    }
}
