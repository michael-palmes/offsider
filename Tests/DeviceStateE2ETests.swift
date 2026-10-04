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
