import Foundation
import Testing

/// `alert` on a wired iPhone or iPad test device, with the playground's permission prompt screen. Each test reinstalls the playground before and after, which resets the permissions it answered for the playground alone.
@Suite("iOS device alert", .serialized, .enabled(if: isIOSDeviceE2EEnabled))
struct IOSDeviceAlertE2ETests {
    static let app = "--app \(IOSDeviceE2E.playgroundBundleID)"

    /// Polls `alert show --json` until the playground's prompt is up; ends the test as skipped on a device that is not a test device.
    static func waitForPrompt(timeout: TimeInterval = 15) async throws -> [String: Any] {
        let deadline = Date().addingTimeInterval(timeout)
        var last = ""
        while Date() < deadline {
            let shown = try await IOSDeviceE2E.offsider("alert show \(app) --json")
            if shown.exitCode == 0, let report = try JSONSerialization.jsonObject(with: Data(shown.stdout.utf8)) as? [String: Any] { return report }
            if shown.stdout.contains(#""reason":"person_required""#) {
                try Test.cancel("skipped: alert reads a prompt only on a test device, and this device is not one")
            }
            last = shown.stderr
            try await Task.sleep(for: .milliseconds(400))
        }
        throw IOSDeviceE2EError(description: "No permission prompt for the playground showed within \(Int(timeout)) s: \(last)")
    }

    static func buttons(_ report: [String: Any]) -> [(label: String, role: String)] {
        let prompt = report["prompt"] as? [String: Any]
        return (prompt?["buttons"] as? [[String: Any]] ?? []).compactMap { button in
            guard let label = button["label"] as? String, let role = button["role"] as? String else { return nil }
            return (label, role)
        }
    }

    /// Runs `body` on a fresh install of the playground on its permission prompt screen, and installs it fresh again afterwards.
    static func onFreshPlayground(_ body: () async throws -> Void) async throws {
        _ = try IOSDeviceE2E.team()
        try await IOSDeviceE2E.requireAwake()
        try await IOSDeviceE2E.reinstallPlayground()
        do {
            try await IOSDeviceE2E.open("permission-prompt", waitingForLabel: "Camera: not-determined")
            try await body()
        } catch {
            // A prompt outlives the app's reinstall, so one the test left up is declined first.
            _ = try? await IOSDeviceE2E.offsider("alert deny \(app)")
            try? await IOSDeviceE2E.reinstallPlayground()
            throw error
        }
        try await IOSDeviceE2E.reinstallPlayground()
    }

    @Test("alert reads the camera prompt over the playground by its ids, refuses it to another app, shows it read only with the rest painted, and deny lands")
    func cameraPrompt() async throws {
        try await Self.onFreshPlayground {
            let none = try await IOSDeviceE2E.offsider("alert show \(Self.app) --json")
            #expect(none.exitCode == 2, "\(none.stderr)")
            #expect(none.stdout.contains(#""reason":"alert_not_shown""#))

            try await IOSDeviceE2E.run("tap --id permission-prompt-ask-camera \(Self.app)")
            let shown = try await Self.waitForPrompt()
            #expect(Self.buttons(shown).map(\.role) == ["deny", "accept"])
            #expect((shown["prompt"] as? [String: Any])?["source"] as? String == "SpringBoard")

            let other = try await IOSDeviceE2E.offsider("alert accept --app com.example.other --json")
            #expect(other.exitCode == 7, "\(other.stderr)")
            #expect(other.stdout.contains(#""reason":"system_prompt_in_front""#))

            let path = FileManager.default.temporaryDirectory.appendingPathComponent("offsider-alert-\(UUID().uuidString).png").path
            defer { try? FileManager.default.removeItem(atPath: path) }
            let shot = try await IOSDeviceE2E.run("screenshot \(Self.app) --json --output \(IOSDeviceE2E.quote(path))")
            let report = try #require(try JSONSerialization.jsonObject(with: Data(shot.stdout.utf8)) as? [String: Any])
            #expect(report["maskUnproven"] as? String == "prompt")
            #expect((report["systemWindow"] as? [String: Any])?["readOnly"] as? Bool == true)
            let tree = try DescribeUITree.parse(try await IOSDeviceE2E.run("describe-ui \(Self.app)").stdout)
            let window = (tree["context"] as? [String: Any])?["window"] as? [String: Any]
            #expect(window?["kind"] as? String == "system" && window?["readOnly"] as? Bool == true)

            let refusedTap = try await IOSDeviceE2E.offsider("tap --id permission-prompt-refresh \(Self.app) --json")
            #expect(refusedTap.exitCode == 7, "a selector tap under the prompt is refused: \(refusedTap.stderr)")

            try await IOSDeviceE2E.run("alert deny \(Self.app)")
            _ = try await IOSDeviceE2E.node(labelled: "Camera: denied")
        }
    }

    @Test("accept on the location prompt picks the grant that lasts while the app is used, never Allow Once, and a text no button has sends nothing")
    func locationPrompt() async throws {
        try await Self.onFreshPlayground {
            try await IOSDeviceE2E.run("tap --id permission-prompt-ask-location \(Self.app)")
            let shown = try await Self.waitForPrompt()
            #expect(Self.buttons(shown).filter { $0.role == "accept" }.map(\.label) == ["Allow While Using App"])
            #expect(Self.buttons(shown).contains { $0.label == "Allow Once" && $0.role == "other" })

            let unknown = try await IOSDeviceE2E.offsider("alert choose \(IOSDeviceE2E.quote("No such button")) \(Self.app) --json")
            #expect(unknown.exitCode == 2, "\(unknown.stderr)")
            // The app cannot be read under its prompt, so the prompt still being there is what shows nothing was sent.
            #expect((try await Self.waitForPrompt(timeout: 5)["prompt"] as? [String: Any])?["title"] as? String == (shown["prompt"] as? [String: Any])?["title"] as? String)

            let accepted = try await IOSDeviceE2E.run("alert accept \(Self.app) --json")
            #expect(accepted.stdout.contains(#""button":"Allow While Using App""#))
            _ = try await IOSDeviceE2E.node(labelled: "Location: when-in-use")
        }
    }
}
