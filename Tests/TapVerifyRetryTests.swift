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

/// Serves `script(taps, reads)` on every read, `reads` counting from the last tap, so a test says what each read after an input shows.
@MainActor
final class ScriptedReadsBackend: FakeDeviceBackend {
    private let script: (_ taps: Int, _ reads: Int) -> UITree
    private var taps = 0
    private var reads = 0

    init(_ script: @escaping (_ taps: Int, _ reads: Int) -> UITree) {
        self.script = script
        super.init(trees: [script(0, 0)])
        session.onPerform = { [unowned self] _ in
            taps += 1
            reads = 0
        }
    }

    override func accessibilityTree(for id: DeviceID, point: UIPoint?) async throws -> UITree {
        defer { reads += 1 }
        return script(taps, reads)
    }
}

@Suite("Tap verify holds a retry while the screen moves, and --verify-id waits for a screen to come to the front")
@MainActor
struct TapVerifyHoldTests {
    static let device = TapVerifyRetryTests.device

    /// A side menu over a page; `menuX` slides the menu.
    static func menu(menuX: Double = 0) -> UITree {
        let page = FakeUI.node(.group, id: "home-screen", frame: FakeUI.frame(0, 0, 402, 874), children: [
            FakeUI.node(.header, label: "Home", frame: FakeUI.frame(60, 60, 282, 20)),
        ])
        let menu = FakeUI.node(.group, id: "side-menu", frame: FakeUI.frame(menuX, 0, 280, 874), children: [
            FakeUI.node(.button, id: "menu-planner", label: "Planner", frame: FakeUI.frame(menuX + 16, 300, 248, 56)),
        ])
        return FakeUI.tree([page, menu])
    }

    /// Runs a verified tap as an agent and returns what it wrote to stdout and stderr, and the error it ended with.
    static func tap(_ arguments: [String], on backend: FakeDeviceBackend) async -> (out: String, err: String, error: (any Error)?) {
        let capture = ConsoleCapture()
        var failure: (any Error)?
        do {
            try await Console.$current.withValue(capture.console(out: .agent, err: .agent)) {
                try await DispatchTracker.$current.withValue(DispatchTracker()) {
                    try await Tap.parse(arguments + ["--device", device.rawValue])
                        .execute(on: DeviceRouter.Route(backend: backend, device: device), progress: VerifyProgress(), logger: OffsiderLogger())
                }
            }
        } catch {
            failure = error
        }
        return (capture.out, capture.err, failure)
    }

    @Test("a menu still sliding in when tapped, which slides away after the tap, is not tapped again where its row was")
    func targetThatSlidAwayIsNotTappedAgain() async throws {
        // Every read moves the menu, so its frames change before the input as well as after it and never count as the tap's effect.
        let backend = ScriptedReadsBackend { taps, reads in
            taps == 0 ? Self.menu(menuX: reads == 0 ? -20 : 0) : Self.menu(menuX: -100 - Double(reads))
        }

        let (_, stderr, error) = await Self.tap(["--label", "Planner", "--verify", "--verify-timeout", "0.5"], on: backend)

        #expect(backend.session.calls.count == 1)
        #expect(error as? ExitCode == ExitCode(5))
        #expect(stderr.contains("watching instead of tapping again"), "\(stderr)")
        #expect(stderr.contains("so it was not sent again"), "\(stderr)")
    }

    @Test("--verify-id for the screen beneath the pushed page taps Back and verifies once that screen is in front")
    func verifyIDBeneathPushedPage() async throws {
        let pushed = FakeUI.tree([
            Self.menu().roots[0].children[0],
            FakeUI.node(.group, id: "details-screen", frame: FakeUI.frame(0, 0, 402, 874), children: [
                FakeUI.node(.button, id: "details-back", label: "Back", frame: FakeUI.frame(5, 61, 40, 40)),
                FakeUI.node(.header, label: "Details", frame: FakeUI.frame(60, 70, 282, 22)),
                FakeUI.node(.button, id: "details-share", label: "Share", frame: FakeUI.frame(16, 790, 370, 49)),
            ]),
        ])
        let backend = FakeDeviceBackend(trees: [pushed, Self.menu()], advanceTreeOnInput: true)

        let (stdout, _, error) = await Self.tap(["--id", "details-back", "--verify-id", "home-screen", "--verify-timeout", "1"], on: backend)

        #expect(error == nil)
        #expect(backend.session.calls.count == 1)
        #expect(stdout.contains("--id 'home-screen' is on screen"), "\(stdout)")
    }
}
