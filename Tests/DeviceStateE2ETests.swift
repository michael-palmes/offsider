import Foundation
import Testing

@Suite("Device state", .serialized, .enabled(if: isE2EEnabled))
struct DeviceStateE2ETests {
    static var udid: String { defaultSimulatorUDID ?? "" }

    static func restoring(_ cleanup: () async -> Void, _ body: () async throws -> Void) async throws {
        do {
            try await body()
        } catch {
            await cleanup()
            throw error
        }
        await cleanup()
    }

    static func simctl(_ arguments: String) async throws -> String {
        try await CommandRunner.runSeparated("xcrun simctl \(arguments)").stdout
    }

    @Test("a status bar override reads back from simctl, and clear empties it")
    func statusBar() async throws {
        try await Self.restoring({ _ = try? await Self.simctl("status_bar \(Self.udid) clear") }) {
            let override = try await TestHelpers.runOffsiderCommandSeparated("status-bar override --time 10:30 --battery 50", simulatorUDID: Self.udid)
            #expect(override.exitCode == 0)
            let list = try await Self.simctl("status_bar \(Self.udid) list")
            #expect(list.contains("Time: 10:30"))
            #expect(list.contains("Battery Level: 50"))
            let show = try await TestHelpers.runOffsiderCommandSeparated("status-bar show --json", simulatorUDID: Self.udid)
            #expect(show.stdout.contains(#""Time":"10:30""#))

            _ = try await TestHelpers.runOffsiderCommandSeparated("status-bar clear", simulatorUDID: Self.udid)
            #expect(!(try await Self.simctl("status_bar \(Self.udid) list")).contains("Time:"))
        }
    }

    static let app = "--app com.mpalmes.offsider.playground"

    @discardableResult
    static func offsider(_ command: String) async throws -> SeparatedCommandOutput {
        let result = try await TestHelpers.runOffsiderCommandSeparated(command, simulatorUDID: udid)
        guard result.exitCode == 0 else { throw TestError.unexpectedState("offsider \(command) exited \(result.exitCode): \(result.stderr)") }
        return result
    }

    static func label(_ text: String, timeout: TimeInterval = 10, _ predicate: (String) -> Bool) async throws -> String {
        try await TestHelpers.waitForLabel(containing: text, timeout: timeout, simulatorUDID: udid, satisfies: predicate)
    }

    @Test("contacts read not determined after reset, authorised after grant and denied after revoke in the app")
    func contactsPermission() async throws {
        try await Self.restoring({ _ = try? await Self.offsider("permission reset contacts \(Self.app)") }) {
            try await Self.offsider("permission reset contacts \(Self.app)")
            try await TestHelpers.launchPlaygroundApp(to: "device-state", simulatorUDID: Self.udid)
            #expect(try await Self.label("Contacts:") { $0 == "Contacts: not-determined" } == "Contacts: not-determined")

            try await Self.offsider("permission grant contacts \(Self.app)")
            try await TestHelpers.launchPlaygroundApp(to: "device-state", simulatorUDID: Self.udid)
            #expect(try await Self.label("Contacts:") { $0 == "Contacts: authorised" } == "Contacts: authorised")

            try await Self.offsider("permission revoke contacts \(Self.app)")
            try await TestHelpers.launchPlaygroundApp(to: "device-state", simulatorUDID: Self.udid)
            #expect(try await Self.label("Contacts:") { $0 == "Contacts: denied" } == "Contacts: denied")
        }
    }

    /// Polls `alert show --json` until the playground's prompt is up; the parsed report.
    static func waitForPrompt(timeout: TimeInterval = 15) async throws -> [String: Any] {
        let deadline = Date().addingTimeInterval(timeout)
        var last = ""
        while Date() < deadline {
            let shown = try await TestHelpers.runOffsiderCommandSeparated("alert show \(app) --json", simulatorUDID: udid)
            if shown.exitCode == 0, let report = try JSONSerialization.jsonObject(with: Data(shown.stdout.utf8)) as? [String: Any] { return report }
            last = shown.stderr
            try await Task.sleep(for: .milliseconds(400))
        }
        throw TestError.unexpectedState("No permission prompt for the playground showed within \(Int(timeout)) s: \(last)")
    }

    static func buttons(_ report: [String: Any]) -> [(label: String, role: String)] {
        let prompt = report["prompt"] as? [String: Any]
        return (prompt?["buttons"] as? [[String: Any]] ?? []).compactMap { button in
            guard let label = button["label"] as? String, let role = button["role"] as? String else { return nil }
            return (label, role)
        }
    }

    /// Opens the prompt screen with `service` reset, and raises its prompt.
    static func raise(_ service: String, reset: String) async throws {
        try await offsider("permission reset \(reset) \(app)")
        try await TestHelpers.launchPlaygroundApp(to: "permission-prompt", simulatorUDID: udid)
        try await offsider("tap --id permission-prompt-ask-\(service)")
    }

    @Test("alert reads the location prompt over the playground, refuses it to another app, denies it, then accepts it while the app is used, and reset makes the app ask again")
    func alertAnswersTheLocationPrompt() async throws {
        try await Self.restoring({ _ = try? await Self.offsider("permission reset location \(Self.app)") }) {
            try await Self.offsider("permission reset location \(Self.app)")
            try await TestHelpers.launchPlaygroundApp(to: "permission-prompt", simulatorUDID: Self.udid)
            #expect(try await Self.label("Location:") { $0 == "Location: not-determined" } == "Location: not-determined")
            let none = try await TestHelpers.runOffsiderCommandSeparated("alert show \(Self.app) --json", simulatorUDID: Self.udid)
            #expect(none.exitCode == 2, "\(none.stderr)")

            try await Self.offsider("tap --id permission-prompt-ask-location")
            let shown = try await Self.waitForPrompt()
            #expect(Self.buttons(shown).filter { $0.role == "accept" }.map(\.label) == ["Allow While Using App"])
            #expect(Self.buttons(shown).filter { $0.role == "deny" }.count == 1)

            let other = try await TestHelpers.runOffsiderCommandSeparated("alert accept --app com.example.other --json", simulatorUDID: Self.udid)
            #expect(other.exitCode == 7, "\(other.stderr)")
            #expect(other.stdout.contains(#""reason":"system_prompt_in_front""#))

            try await Self.offsider("alert deny \(Self.app)")
            #expect(try await Self.label("Location:") { $0 == "Location: denied" } == "Location: denied")

            try await Self.raise("location", reset: "location")
            _ = try await Self.waitForPrompt()
            let accepted = try await Self.offsider("alert accept \(Self.app) --json")
            #expect(accepted.stdout.contains(#""button":"Allow While Using App""#))
            #expect(try await Self.label("Location:") { $0 == "Location: when-in-use" } == "Location: when-in-use")

            try await Self.raise("location", reset: "location")
            _ = try await Self.waitForPrompt()
            try await Self.offsider("alert choose \"Allow Once\" \(Self.app)")
            #expect(try await Self.label("Location:") { $0 == "Location: when-in-use" } == "Location: when-in-use")
        }
    }

    @Test("a privacy prompt is answered by its button ids: the camera prompt accepts to authorised and denies to denied")
    func alertAnswersTheCameraPrompt() async throws {
        try await Self.restoring({ _ = try? await Self.offsider("permission reset all \(Self.app)") }) {
            try await Self.raise("camera", reset: "all")
            let shown = try await Self.waitForPrompt()
            #expect(Self.buttons(shown).map(\.role).sorted() == ["accept", "deny"])
            try await Self.offsider("alert accept \(Self.app)")
            #expect(try await Self.label("Camera:") { $0 == "Camera: authorised" } == "Camera: authorised")

            try await Self.raise("camera", reset: "all")
            _ = try await Self.waitForPrompt()
            try await Self.offsider("alert deny \(Self.app)")
            #expect(try await Self.label("Camera:") { $0 == "Camera: denied" } == "Camera: denied")
        }
    }

    @Test("two prompts in turn: accepting the camera names the location prompt that follows, which deny then answers")
    func alertFollowsToTheNextPrompt() async throws {
        try await Self.restoring({ _ = try? await Self.offsider("permission reset all \(Self.app)") }) {
            try await Self.raise("both", reset: "all")
            _ = try await Self.waitForPrompt()
            let first = try await Self.offsider("alert accept \(Self.app) --json")
            let report = try #require(try JSONSerialization.jsonObject(with: Data(first.stdout.utf8)) as? [String: Any])
            let next = try #require(report["next"] as? [String: Any], "the location prompt did not follow: \(first.stdout)")
            #expect((next["title"] as? String)?.contains("location") == true)
            try await Self.offsider("alert deny \(Self.app)")
            #expect(try await Self.label("Location:") { $0 == "Location: denied" } == "Location: denied")
            #expect(try await Self.label("Camera:") { $0 == "Camera: authorised" } == "Camera: authorised")
        }
    }

    @Test("with Face ID enrolled, match authenticates the app, no-match keeps it asking, and unenrol leaves it unavailable")
    func faceID() async throws {
        let before = try await Self.offsider("biometric status").stdout
        let restore = "biometric \(before.contains("not enrolled") ? "unenrol" : "enrol")"
        try await Self.restoring({ _ = try? await TestHelpers.runOffsiderCommandSeparated(restore, simulatorUDID: Self.udid) }) {
            try await Self.offsider("biometric enrol")
            #expect(try await Self.offsider("biometric status").stdout.contains("Face ID: enrolled"))
            try await TestHelpers.launchPlaygroundApp(to: "device-state", simulatorUDID: Self.udid)
            #expect(try await Self.label("Biometry:") { $0 == "Biometry: face" } == "Biometry: face")

            try await Self.authenticate()
            let match = try await Self.offsider("biometric match --json")
            #expect(match.stdout.contains(#""sent":"com.apple.BiometricKit_Sim.pearl.match""#))
            #expect(try await Self.label("Biometric Result:") { $0 == "Biometric Result: matched" } == "Biometric Result: matched")

            try await Self.authenticate()
            try await Self.offsider("biometric no-match")
            let early = try? await Self.label("Biometric Result:", timeout: 5) { $0 == "Biometric Result: matched" }
            #expect(early == nil, "a no-match authenticated the app")
            try await Self.offsider("biometric match")
            #expect(try await Self.label("Biometric Result:", timeout: 15) { $0 == "Biometric Result: matched" } == "Biometric Result: matched")

            try await Self.offsider("biometric unenrol")
            #expect(try await Self.offsider("biometric status").stdout.contains("Face ID: not enrolled"))
            try await TestHelpers.launchPlaygroundApp(to: "device-state", simulatorUDID: Self.udid)
            #expect(try await Self.label("Biometry:") { $0 == "Biometry: unavailable" } == "Biometry: unavailable")
        }
    }

    /// Taps Authenticate, accepting the one-time Face ID usage prompt; the Face ID sheet hides the app's labels while it asks.
    static func authenticate() async throws {
        try await offsider("tap --id device-state-authenticate")
        try await Task.sleep(for: .seconds(2))
        _ = try? await TestHelpers.runOffsiderCommandSeparated("tap --label OK", simulatorUDID: udid)
        try await Task.sleep(for: .seconds(2))
    }
}
