import Foundation
import OffsiderCore
import Testing
@testable import Offsider

@Suite("Assert command")
@MainActor
struct AssertCommandTests {
    static let device = DeviceID(rawValue: "fake-device", platform: .ios)

    private static func screen(countValue: String = "2", saveY: Double = 600) -> UITree {
        FakeUI.tree(width: 393, height: 852, [
            FakeUI.node(.text, id: "count", label: "Count", value: countValue, frame: FakeUI.frame(20, 100, 200, 30)),
            FakeUI.node(.button, id: "save", label: "Save", frame: FakeUI.frame(20, saveY, 350, 44)),
        ])
    }

    private static func check(_ arguments: [String], on tree: UITree) async throws -> (Assert, WaitOutcome, FakeDeviceBackend) {
        let backend = FakeDeviceBackend(trees: [tree, screen(countValue: "3")])
        let command = try Assert.parse(arguments + ["--device", device.rawValue])
        let outcome = try await command.evaluate(on: DeviceRouter.Route(backend: backend, device: device), logger: OffsiderLogger())
        return (command, outcome, backend)
    }

    @Test("a --has-value mismatch fails with the actual and expected values after one read")
    func hasValueMismatch() async throws {
        let (command, outcome, backend) = try await Self.check(["--id", "count", "--has-value", "3"], on: Self.screen(countValue: "2"))

        #expect(!outcome.met)
        #expect(backend.treeReads == 1)
        #expect(command.failureLine(outcome) == "✗ Assertion failed: --id 'count' has value '2', expected '3'.")
        let json = WaitReport(outcome).jsonLine()
        #expect(json.hasPrefix(#"{"met":false,"elapsedMs":"#))
        #expect(json.hasSuffix(#""reason":"has value '2', expected '3'","match":null,"matched":null,"nearest":[],"leaveOut":null}"#))
    }

    @Test("--has-value that is the element's label says to use --label")
    func hasValueThatIsTheLabel() async throws {
        let (command, outcome, _) = try await Self.check(["--id", "save", "--has-value", "Save"], on: Self.screen())

        #expect(!outcome.met)
        #expect(command.failureLine(outcome) == "✗ Assertion failed: --id 'save' has no value, expected 'Save'; 'Save' is its label: use --label 'Save'.")
    }

    @Test("--id with --label passes only when one element matches both")
    func idAndLabel() async throws {
        let (both, met, _) = try await Self.check(["--id", "save", "--label", "Save"], on: Self.screen())
        #expect(met.met)
        #expect(both.successLine(met) == "✓ --id 'save' --label 'Save' is on screen")

        let (_, unmet, _) = try await Self.check(["--id", "save", "--label", "Cancel"], on: Self.screen())
        #expect(!unmet.met)
    }

    @Test("a matching value passes and reports the element")
    func hasValueMatch() async throws {
        let (command, outcome, _) = try await Self.check(["--id", "count", "--has-value", "3"], on: Self.screen(countValue: "3"))

        #expect(outcome.met)
        #expect(outcome.match?.id == "count")
        #expect(command.successLine(outcome) == "✓ --id 'count' is on screen with value '3'")
    }

    @Test("an off-screen element fails unless --allow-offscreen")
    func offScreenNeedsAllowOffscreen() async throws {
        let parked = Self.screen(saveY: 10700)

        let (strict, failed, _) = try await Self.check(["--id", "save"], on: parked)
        #expect(!failed.met)
        #expect(strict.failureLine(failed) == "✗ Assertion failed: --id 'save' is off screen at (20, 10700) 350x44.")

        let (_, passed, _) = try await Self.check(["--id", "save", "--allow-offscreen"], on: parked)
        #expect(passed.met)
    }

    @Test("a missing element fails as not found and passes with --gone")
    func missingElement() async throws {
        let (command, outcome, _) = try await Self.check(["--id", "banner"], on: Self.screen())
        #expect(command.failureLine(outcome) == "✗ Assertion failed: --id 'banner' was not found.")

        let (gone, goneOutcome, _) = try await Self.check(["--id", "banner", "--gone"], on: Self.screen())
        #expect(goneOutcome.met)
        #expect(gone.successLine(goneOutcome) == "✓ --id 'banner' is gone")
    }

    @Test("--gone fails while the element is on screen")
    func goneFailsWhileVisible() async throws {
        let (command, outcome, _) = try await Self.check(["--id", "save", "--gone"], on: Self.screen())

        #expect(!outcome.met)
        #expect(command.failureLine(outcome) == "✗ Assertion failed: --id 'save' is still on screen.")
    }

    @Test("several on-screen matches still pass, with no single match reported")
    func severalMatchesPass() async throws {
        let (_, outcome, _) = try await Self.check(["--label", "Save"], on: FakeUI.tree([
            FakeUI.node(.button, label: "Save", frame: FakeUI.frame(20, 100, 100, 44)),
            FakeUI.node(.button, label: "Save", frame: FakeUI.frame(20, 300, 100, 44)),
        ]))

        #expect(outcome.met)
        #expect(outcome.match == nil)
    }

    @Test("assert needs a selector")
    func needsSelector() {
        #expect(throws: (any Error).self) {
            try Assert.parse(["--gone", "--device", Self.device.rawValue])
        }
    }

    // MARK: Redaction

    @Test("--has-value compares the real value, and the report shows it redacted with a note")
    func hasValueRedacted() async throws {
        let card = "4111 1111 1111 1111"
        let (command, outcome, _) = try await Self.check(["--id", "count", "--has-value", card], on: Self.screen(countValue: card))

        #expect(outcome.met)
        #expect(Wait.redactionNote(outcome, checked: command.selector) == " (matched on the real text; describe-ui shows it redacted)")
        let json = WaitReport(Wait.shown(outcome)).jsonLine()
        #expect(json.contains("[redacted card]") && !json.contains("4111"))
    }

    @Test("a mismatch never prints a secret value the tree output hides")
    func mismatchRedacted() async throws {
        let (command, outcome, _) = try await Self.check(["--id", "count", "--has-value", "3"], on: Self.screen(countValue: "4111 1111 1111 1111"))

        #expect(!outcome.met)
        #expect(LogRedactor.redactValue(command.failureLine(outcome)).text == "✗ Assertion failed: --id 'count' has value '[redacted card]', expected '3'.")
        #expect(!WaitReport(Wait.shown(outcome)).jsonLine().contains("4111"))
    }

    @Test("an ordinary match carries no redaction note")
    func noNote() async throws {
        let (command, outcome, _) = try await Self.check(["--id", "count", "--has-value", "3"], on: Self.screen(countValue: "3"))
        #expect(Wait.redactionNote(outcome, checked: command.selector).isEmpty)
    }
}
