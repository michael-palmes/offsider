import Foundation
import Testing
@testable import OffsiderAndroid

extension AndroidE2E {
    /// A gRPC client for the guarded emulator, for checks Offsider has no command for (the clipboard).
    static func emulatorClient() async throws -> any EmulatorControlling {
        let serial = try await serial()
        let host = AndroidHost.live()
        let port = Int(serial.dropFirst("emulator-".count))
        guard let discovery = EmulatorDiscovery.live(host: host).first(where: { $0.consolePort == port }) else {
            throw AndroidE2EError(description: "\(serial) has no live discovery file, so it has no gRPC endpoint.")
        }
        let auth = try await EmulatorAuth.choose(for: discovery, host: host)
        return try await GrpcEmulatorConnector().connect(discovery: discovery, auth: auth)
    }
}

@Suite("Android type", .serialized, .enabled(if: isAndroidE2EEnabled))
struct AndroidTypeTests {
    @Test("ASCII text is typed into the focused field")
    func ascii() async throws {
        try await AndroidE2E.open("text-input", waitingFor: "text-input-field")
        try await AndroidE2E.run("tap --id text-input-field")
        try await AndroidE2E.run("type 'hello world'")
        _ = try await AndroidE2E.waitForLabel(of: "character-count") { $0 == "Characters: 11" }
        #expect(try await AndroidE2E.label(of: "word-count") == "Words: 2")
    }

    @Test("non-ASCII text is pasted whole and the clipboard is restored")
    func unicodeRestoresClipboard() async throws {
        let emulator = try await AndroidE2E.emulatorClient()
        let sentinel = "offsider-sentinel-\(UUID().uuidString)"
        try await emulator.setClipboard(sentinel)
        try await AndroidE2E.open("text-input", waitingFor: "text-input-field")
        try await AndroidE2E.run("tap --id text-input-field")

        let text = "h\u{E9}llo 日本 🙂"
        try await AndroidE2E.type(text)

        let field = try await AndroidE2E.waitForNode { $0["id"] as? String == "text-input-field" && $0["value"] as? String == text }
        #expect((field["value"] as? String).map { Array($0.unicodeScalars) } == Array(text.unicodeScalars))
        #expect(try await AndroidE2E.label(of: "character-count") == "Characters: 10")
        #expect(try await emulator.clipboard() == sentinel)
        await emulator.close()
    }
}

@Suite("Android batch", .serialized, .enabled(if: isAndroidE2EEnabled))
struct AndroidBatchTests {
    @Test("the six-step login flow runs in one batch")
    func loginFlow() async throws {
        try await AndroidE2E.open("batch-login-flow", waitingFor: "batch-login-email-field")
        let steps = [
            "type 'cam@example.com'", "tap --label Continue", "type 'supersecret'",
            "tap --label 'Sign In'", "tap --label 'Open Settings'", "tap --label 'Toggle Preference'",
        ]
        let arguments = steps.map { "--step \(AndroidE2E.quote($0))" }.joined(separator: " ")
        let result = try await AndroidE2E.run("batch --ax-cache perStep --wait-timeout 15 --poll-interval 0.2 \(arguments)", timeout: 240)
        #expect(result.stdout.contains("Batch completed successfully (6 steps)"))
        _ = try await AndroidE2E.waitForLabel(of: "batch-login-current-screen") { $0 == "Current Screen: Settings" }
    }

    @Test("an iOS-only button step is a usage error")
    func iosButtonStep() async throws {
        let result = try await AndroidE2E.offsider("batch --step 'button siri'")
        #expect(result.exitCode != 0)
        #expect(result.stderr.contains("The siri button is iOS only"))
    }
}

@Suite("Android verify", .serialized, .enabled(if: isAndroidE2EEnabled))
struct AndroidVerifyTests {
    @Test("a verified tap exits 0 with a JSON report")
    func verifiedTap() async throws {
        try await AndroidE2E.open("tap-test", waitingFor: "tap-test-area")
        let result = try await AndroidE2E.run("tap --id tap-test-area --verify --json")
        let report = try #require(try JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any])
        #expect(report["verified"] as? Bool == true)
    }

    @Test("a key with no observable effect exits 5")
    func noEffectExits5() async throws {
        try await AndroidE2E.open("tap-test", waitingFor: "tap-test-area")
        try await AndroidE2E.run("key 4")
        let result = try await AndroidE2E.offsider("key 4 --verify")
        #expect(result.exitCode == 5)
        #expect(result.stderr.contains("nothing observable changed"))
    }
}
