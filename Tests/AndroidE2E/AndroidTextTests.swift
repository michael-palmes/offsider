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
        try await AndroidE2E.run("type \(AndroidE2E.quote(text))")

        let field = try await AndroidE2E.waitForNode { $0["id"] as? String == "text-input-field" && $0["value"] as? String == text }
        #expect((field["value"] as? String).map { Array($0.unicodeScalars) } == Array(text.unicodeScalars))
        #expect(try await AndroidE2E.label(of: "character-count") == "Characters: 10")
        #expect(try await emulator.clipboard() == sentinel)
        await emulator.close()
    }

    @Test("--replace leaves the field holding only the new text")
    func replace() async throws {
        try await AndroidE2E.open("text-input", waitingFor: "text-input-field")
        try await AndroidE2E.run("tap --id text-input-field")
        try await AndroidE2E.run("type 'hello'")
        _ = try await AndroidE2E.waitForLabel(of: "character-count") { $0 == "Characters: 5" }

        try await AndroidE2E.run("type --replace 'bye'")
        _ = try await AndroidE2E.waitForFieldValue("bye")
        _ = try await AndroidE2E.waitForLabel(of: "character-count") { $0 == "Characters: 3" }
    }

    @Test("--replace with empty text clears the field")
    func replaceWithNothing() async throws {
        try await AndroidE2E.open("text-input", waitingFor: "text-input-field")
        try await AndroidE2E.run("tap --id text-input-field")
        try await AndroidE2E.run("type 'hello'")
        _ = try await AndroidE2E.waitForLabel(of: "character-count") { $0 == "Characters: 5" }

        try await AndroidE2E.run("type --replace ''")
        _ = try await AndroidE2E.waitForFieldValue("")
        #expect(try await AndroidE2E.label(of: "character-count") == nil, "the app still counts characters, so onChangeText did not see the empty text")
    }

    @Test("--replace sets non-ASCII text over adb alone")
    func replaceUnicodeWithoutGrpc() async throws {
        let adbOnly = ["OFFSIDER_ANDROID_TRANSPORT": "adb"]
        try await AndroidE2E.open("text-input", waitingFor: "text-input-field")
        try await AndroidE2E.run("tap --id text-input-field", environment: adbOnly)

        let text = "h\u{E9}llo 日本"
        try await AndroidE2E.run("type --replace \(AndroidE2E.quote(text))", environment: adbOnly)

        let field = try await AndroidE2E.waitForFieldValue(text)
        #expect((field["value"] as? String).map { Array($0.unicodeScalars) } == Array(text.unicodeScalars))
        _ = try await AndroidE2E.waitForLabel(of: "character-count") { $0 == "Characters: 8" }
    }

    @Test("--replace with a trailing newline sets the text, then presses Return to submit the field")
    func replaceAndSubmit() async throws {
        try await AndroidE2E.open("batch-login-flow", waitingFor: "batch-login-email-field")
        try await AndroidE2E.run("tap --id batch-login-email-field")
        #expect(try await AndroidE2E.eventually(timeout: 20) { try await AndroidE2E.keyboardShown() }, "the keyboard never came up for the email field")

        try await AndroidE2E.run("type --replace $'a@b.co\\n'")

        let field = try await AndroidE2E.waitForFieldValue("a@b.co", id: "batch-login-email-field")
        let submitted = try await AndroidE2E.eventually(timeout: 20) {
            let tree = try await AndroidE2E.tree()
            let email = AndroidE2E.nodes(in: tree).first { $0["id"] as? String == "batch-login-email-field" }
            let focused = (email?["state"] as? [String: Any])?["focused"] as? Bool
            let keyboard = ((tree["roots"] as? [[String: Any]]) ?? []).contains { $0["role"] as? String == "keyboard" }
            return focused == false && !keyboard
        }
        #expect(submitted, "Return did not submit the single-line field (it kept focus or the keyboard stayed): \(field)")
    }

    @Test("--replace with nothing focused fails and names the missing focus")
    func replaceWithoutFocus() async throws {
        try await AndroidE2E.open("tap-test", waitingFor: "tap-test-area")
        let result = try await AndroidE2E.offsider("type --replace 'x'")
        #expect(result.exitCode == 1)
        #expect(result.stderr.contains("type --replace needs a focused text field"))
        #expect(result.stderr.contains("nothing has input focus"))
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

    @Test("a tap step then a type --replace step replace the field's text in one batch")
    func tapThenReplace() async throws {
        try await AndroidE2E.open("text-input", waitingFor: "text-input-field")
        try await AndroidE2E.run("tap --id text-input-field")
        try await AndroidE2E.run("type 'hello'")
        _ = try await AndroidE2E.waitForLabel(of: "character-count") { $0 == "Characters: 5" }

        let steps = ["tap --id text-input-field", "type --replace 'abc'"].map { "--step \(AndroidE2E.quote($0))" }.joined(separator: " ")
        let result = try await AndroidE2E.run("batch --wait-timeout 15 \(steps)", timeout: 180)

        #expect(result.stdout.contains("Batch completed successfully (2 steps)"))
        _ = try await AndroidE2E.waitForFieldValue("abc")
        _ = try await AndroidE2E.waitForLabel(of: "character-count") { $0 == "Characters: 3" }
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

    /// The 3 s target holds on a quiet host; under load this bound only catches a fallback to uiautomator (about 13 s).
    @Test("a verified tap on a warm screen is quick and never falls back to uiautomator")
    func verifiedTapTime() async throws {
        try await AndroidE2E.open("tap-test", waitingFor: "tap-test-area")
        let started = Date()
        let result = try await AndroidE2E.run("tap --id tap-test-area --verify")
        let elapsed = Date().timeIntervalSince(started)
        print("verified tap took \(Int(elapsed * 1000)) ms")

        #expect(!result.stderr.contains("Warning:"), "stderr: \(result.stderr)")
        #expect(elapsed < 10, "a verified tap took \(elapsed) s")
        _ = try await AndroidE2E.waitForLabel(of: "tap-count") { $0 == "Tap Count: 1" }
    }

    @Test("a verified type exits 0 once the field changes")
    func verifiedType() async throws {
        try await AndroidE2E.open("text-input", waitingFor: "text-input-field")
        try await AndroidE2E.run("tap --id text-input-field")
        let result = try await AndroidE2E.run("type 'x' --verify --json")
        let report = try #require(try JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any])
        #expect(report["verified"] as? Bool == true)
        _ = try await AndroidE2E.waitForLabel(of: "character-count") { $0 == "Characters: 1" }
    }

    @Test("a verified back button exits 0 once the screen changes")
    func verifiedBack() async throws {
        try await AndroidE2E.open("tap-test", waitingFor: "tap-test-area")
        let result = try await AndroidE2E.run("button back --verify --json")
        let report = try #require(try JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any])
        #expect(report["verified"] as? Bool == true)
        _ = try await AndroidE2E.waitForNode { $0["id"] as? String == "menu-title" }
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
