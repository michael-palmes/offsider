import ArgumentParser
import Foundation
import OffsiderCore
import Testing
@testable import Offsider

@Suite("Tap verify retries")
@MainActor
struct TapVerifyRetryTests {
    static let device = DeviceID(rawValue: "fake-device", platform: .ios)

    private static func screen(_ role: UIRole, value: String? = nil) -> UITree {
        FakeUI.tree([
            FakeUI.node(role, id: "alerts", label: "Alerts", value: value, frame: FakeUI.frame(300, 200, 60, 36)),
        ])
    }

    /// Taps sent by a verified tap on a screen that never changes, which ends in exit 5.
    private static func taps(_ role: UIRole, _ arguments: [String] = []) async throws -> Int {
        let backend = FakeDeviceBackend(trees: [screen(role, value: role == .button ? nil : "0")])
        let tap = try Tap.parse(["--id", "alerts", "--verify", "--verify-timeout", "0.5"] + arguments + ["--device", device.rawValue])
        await #expect(throws: ExitCode(5)) {
            try await DispatchTracker.$current.withValue(DispatchTracker()) {
                try await tap.execute(on: DeviceRouter.Route(backend: backend, device: device), progress: VerifyProgress(), logger: OffsiderLogger())
            }
        }
        return backend.session.calls.count
    }

    @Test("a switch, checkbox or radio button gets one tap by default, since a second could flip back a late change", arguments: [UIRole.switch, .checkbox, .radioButton])
    func stateTargetTapsOnce(role: UIRole) async throws {
        #expect(try await Self.taps(role) == 1)
    }

    @Test("--retries 1 on a switch still taps again")
    func explicitRetryOnSwitch() async throws {
        #expect(try await Self.taps(.switch, ["--retries", "1"]) == 2)
    }

    @Test("a button keeps the default retry")
    func buttonRetries() async throws {
        #expect(try await Self.taps(.button) == 2)
    }

    @Test("the failure line for a switch says why it did not tap again and how to wait for the new state")
    func lateStateHint() throws {
        let node = FakeUI.node(.switch, id: "alerts", label: "Alerts", value: "0")
        let request = VerifyRequest(
            command: "tap", subject: "Tap on id=alerts", target: "id=alerts",
            backend: FakeDeviceBackend(trees: []), device: Self.device,
            options: try VerificationOptions.parse(["--verify"]), styles: [.physical], targetNode: node
        )

        let line = VerifyOutput.unverifiedLine(Verifier.Outcome(verified: false, attempts: 1, change: .none, style: .physical, summary: nil), for: request)

        #expect(line.contains("a second tap would undo the first"))
        #expect(line.contains("offsider wait --id alerts --has-value 1 --timeout 10 --device fake-device"))
    }

    @Test("the wait it suggests uses the tap's own label, quoted for the shell, and a value selector falls back to the label", arguments: [
        ("label=Slow Commit Alerts", "offsider wait --label 'Slow Commit Alerts' --has-value 0"),
        ("value=1", "offsider wait --label 'Slow Commit Alerts' --has-value 0"),
    ])
    func lateStateHintSelector(selector: String, expected: String) throws {
        let node = FakeUI.node(.switch, id: "switch-test-screen", label: "Slow Commit Alerts", value: "1")
        let request = VerifyRequest(
            command: "tap", subject: "Tap on \(selector)", target: selector,
            backend: FakeDeviceBackend(trees: []), device: Self.device,
            options: try VerificationOptions.parse(["--verify"]), styles: [.physical], targetNode: node
        )

        let line = VerifyOutput.unverifiedLine(Verifier.Outcome(verified: false, attempts: 1, change: .none, style: .physical, summary: nil), for: request)

        #expect(line.contains(expected))
    }

    @Test("a button's failure line keeps the describe-ui advice and says nothing about undoing")
    func buttonLineUnchanged() throws {
        let request = VerifyRequest(
            command: "tap", subject: "Tap on id=save", target: "id=save",
            backend: FakeDeviceBackend(trees: []), device: Self.device,
            options: try VerificationOptions.parse(["--verify"]), styles: [.simulator, .physical],
            targetNode: FakeUI.node(.button, id: "save", label: "Save")
        )

        let line = VerifyOutput.unverifiedLine(Verifier.Outcome(verified: false, attempts: 2, change: .none, style: .physical, summary: nil), for: request)

        #expect(line.contains("Check the target with describe-ui"))
        #expect(!line.contains("undo"))
    }
}
