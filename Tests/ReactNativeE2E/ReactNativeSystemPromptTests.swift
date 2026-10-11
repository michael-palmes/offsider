import Foundation
import Testing

/// iOS offers to save a password once a filled password field leaves the screen; the prompt is drawn by another process over the app.
@Suite("React Native system prompt", .serialized, .enabled(if: isRNIOSE2EEnabled))
struct ReactNativeSystemPromptTests {
    @Test("after a sign-in, describe-ui names iOS's Save Password? prompt, tap under it refuses with nothing sent, and a tap on its backdrop dismisses it")
    func savePasswordPrompt() async throws {
        let app = RNApp(.ios)
        try await app.open("user-switch-test")
        try await app.run("type \(AndroidE2E.quote("prompt@example.test")) --into-id user-switch-test-email")
        try await app.run("type \(AndroidE2E.quote("not-a-secret")) --into-id user-switch-test-password")
        try await app.run("tap --id user-switch-test-submit")
        _ = try await app.waitForLabel(of: "user-switch-test-state") { $0 == "Session: Signed in" }

        let window = try await SavePasswordPrompt.wait(on: app)
        #expect(window["title"] as? String == "Save Password?")
        #expect(window["package"] as? String == "SafariViewService")

        let refused = try await app.offsider("tap --id user-switch-test-sign-out --verify --json")
        #expect(refused.exitCode == 1, "\(refused.stderr)")
        let error = try #require(SavePasswordPrompt.error(in: refused))
        #expect(error["reason"] as? String == "target_covered")
        #expect(error["dispatched"] as? String == "no")
        let cover = try #require(error["coveredBy"] as? [String: Any])
        #expect(cover["evidence"] as? String == "otherProcess")
        #expect(cover["process"] as? String == "SafariViewService")
        #expect(cover["screen"] as? String == "Save Password?")
        #expect((error["message"] as? String)?.contains("only dismiss it") == true, "\(error)")
        #expect(try await app.label(of: "user-switch-test-state") == "Session: Signed in")

        try await SavePasswordPrompt.dismiss(on: app, at: "user-switch-test-sign-out")
        try await app.run("tap --id user-switch-test-sign-out")
        _ = try await app.waitForLabel(of: "user-switch-test-state") { $0 == "Session: Signed out" }
    }
}

/// iOS's Save Password? prompt as `describe-ui` and `tap` report it.
enum SavePasswordPrompt {
    /// Waits for `describe-ui` to name a system window over the app; returns it.
    static func wait(on app: RNApp, timeout: TimeInterval = 15) async throws -> [String: Any] {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let window = try await window(on: app) {
                return window
            }
            try await Task.sleep(for: .milliseconds(300))
        }
        throw DescribeUIError(description: "No system prompt showed within \(Int(timeout)) s after the sign-in")
    }

    static func window(on app: RNApp) async throws -> [String: Any]? {
        let context = try await app.tree()["context"] as? [String: Any]
        guard let window = context?["window"] as? [String: Any], window["kind"] as? String == "system" else { return nil }
        return window
    }

    /// The JSON error a failed `--verify --json` printed.
    static func error(in output: SeparatedCommandOutput) -> [String: Any]? {
        let object = try? JSONSerialization.jsonObject(with: Data(output.stdout.utf8)) as? [String: Any]
        return object?["error"] as? [String: Any]
    }

    /// True when a `tap --json` was refused because another process's prompt covers its target.
    static func refused(_ output: SeparatedCommandOutput) -> Bool {
        let cover = error(in: output)?["coveredBy"] as? [String: Any]
        return cover?["evidence"] as? String == "otherProcess"
    }

    /// Taps the prompt's backdrop where `id` sits under it, as the refusal suggests, and waits for the prompt to go.
    static func dismiss(on app: RNApp, at id: String) async throws {
        let centre = try await app.centre(of: id)
        try await app.run("tap -x \(centre.x) -y \(centre.y)")
        let deadline = Date().addingTimeInterval(10)
        while try await window(on: app) != nil {
            guard Date() < deadline else {
                throw DescribeUIError(description: "The system prompt was still up 10 s after a tap on its backdrop")
            }
            try await Task.sleep(for: .milliseconds(300))
        }
    }
}
