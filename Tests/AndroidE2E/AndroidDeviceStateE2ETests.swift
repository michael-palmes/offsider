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

    static func runtimeState(_ permission: String) async throws -> String {
        let dump = try await AndroidE2E.shell("dumpsys package \(AndroidE2E.package)")
        return dump.split(whereSeparator: \.isNewline).first { $0.contains("android.permission.\(permission): granted=") }.map(String.init) ?? ""
    }

    @Test("granting camera shows granted on the permission-state screen, and reset denies it with the user flags cleared")
    func cameraPermission() async throws {
        try await AndroidE2E.ensurePlaygroundInstalled()
        try await AndroidE2E.run("permission reset camera notifications \(Self.app)")
        try await Self.restoring({ _ = try? await AndroidE2E.offsider("permission reset camera notifications \(Self.app)") }) {
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
