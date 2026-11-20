import Foundation
import OffsiderCore
import Testing
@testable import Offsider

/// No selector answers a guess about text Offsider hides: a password field's, shown or revealed, or a label or value a mask hides. The text is made up.
@Suite("Selectors answer no guess about hidden text")
@MainActor
struct GuessOracleTests {
    typealias Screen = NearMissSecretTests
    static let device = Screen.device

    static func assertOutcome(_ arguments: [String]) async throws -> WaitOutcome {
        try await Screen.masked {
            try await Assert.parse(arguments + ["--device", Self.device.rawValue]).evaluate(on: Screen.route, logger: OffsiderLogger())
        }
    }

    static func waitOutcome(_ arguments: [String]) async throws -> WaitOutcome {
        try await Screen.masked {
            try await Wait.parse(arguments + ["--timeout", "0", "--device", Self.device.rawValue])
                .evaluate(on: Screen.route, logger: OffsiderLogger(), clock: ScriptedClock().poll)
        }
    }

    static func tapMessage(_ query: AccessibilityQuery) async -> String {
        await Screen.masked { Screen.missMessage(query, roots: Screen.screen().roots) }
    }

    // MARK: Password fields

    @Test("--has-value on a password field, revealed or not, is refused the same whatever the text", arguments: ["password-field", "pin-field"])
    func hasValueRefused(id: String) async throws {
        var messages: [String] = []
        for text in [Screen.revealedText, Screen.secureText, "nope"] {
            for command in ["assert", "wait"] {
                let arguments = ["--id", id, "--has-value", text]
                let refusal = await #expect(throws: SelectorRefusal.self) {
                    _ = command == "assert" ? try await Self.assertOutcome(arguments) : try await Self.waitOutcome(arguments)
                }
                #expect(refusal?.reason == .secureFieldArgument && refusal?.reason.exitCode == .usage)
                messages.append(refusal?.failureMessage ?? "")
            }
        }
        #expect(Set(messages).count == 1, "\(messages)")
        #expect(Screen.hidesEverySecret(messages[0]))
    }

    @Test("--value never matches a revealed password field's text, in assert, wait and tap")
    func revealedValueNeverMatches() async throws {
        #expect(try await !Self.assertOutcome(["--value", Screen.revealedText]).met)
        #expect(try await !Self.waitOutcome(["--value", Screen.revealedText]).met)
        let tap = await Self.tapMessage(.value(Screen.revealedText))
        #expect(tap.hasPrefix("No accessibility element matched --value"), "\(tap)")
    }

    // MARK: Masked labels and values

    @Test("a masked label matches no label selector, a right guess and a wrong one read the same, and the miss names --id", arguments: [
        ["--label-contains", "Member"], ["--label-contains", "Zebra"], ["--label", "Member code"], ["--id", "member-code", "--label-contains", "Member"],
    ])
    func maskedLabelNeverMatches(arguments: [String]) async throws {
        let assert = try await Self.assertOutcome(arguments)
        let wait = try await Self.waitOutcome(arguments)
        #expect(!assert.met && !wait.met)
        if arguments.first != "--id" {
            #expect(assert.reason.contains("select those by --id"), "\(assert.reason)")
            #expect(!assert.reason.hasSuffix("."), "the failure line adds its own full stop: \(assert.reason)")
            #expect(wait.reason.contains("select those by --id"), "\(wait.reason)")
        }
    }

    @Test("tap, type --into-* and the other selector commands never match a masked label or value, and say to use --id", arguments: [
        AccessibilityQuery.labelContains("Member"), .label("Member code"), .value(Screen.maskedText), .value("kiwi"),
    ])
    func resolverNeverMatchesMasked(query: AccessibilityQuery) async {
        let message = await Self.tapMessage(query)
        #expect(message.hasPrefix("No accessibility element matched \(query.kind)"), "\(message)")
        #expect(message.contains("select those by --id"), "\(message)")
        #expect(Screen.hidesEverySecret(message.replacingOccurrences(of: query.rawValue, with: "")))
    }

    @Test("--gone by a label or value a mask hides never reports the element gone, whatever was asked", arguments: [["--label-contains", "Member"], ["--label-contains", "Zebra"], ["--value", "kiwi"]])
    func goneNeverMetOnHiddenField(arguments: [String]) async throws {
        let wait = try await Self.waitOutcome(arguments + ["--gone"])
        let assert = try await Self.assertOutcome(arguments + ["--gone"])
        #expect(!wait.met && !assert.met)
        #expect(wait.reason.contains("select those by --id"), "\(wait.reason)")
    }

    @Test("a masked element is still found by --id, and an exact --has-value on its masked value still confirms it")
    func idAndExactValueStillWork() async throws {
        #expect(try await Self.assertOutcome(["--id", "member-code"]).met)
        #expect(try await Self.assertOutcome(["--id", "member-code", "--has-value", Screen.maskedText]).met)
        #expect(try await !Self.assertOutcome(["--id", "member-code", "--has-value", "kiwi"]).met)
    }

    @Test("an unmasked label and value still match as before")
    func plainTextStillMatches() async throws {
        #expect(try await Self.assertOutcome(["--label-contains", "Plan"]).met)
        #expect(try await Self.assertOutcome(["--value", "Standard yearly"]).met)
        let reason = try await Self.assertOutcome(["--label-contains", "Nothing like it"]).reason
        #expect(reason.contains("select those by --id"), "a masked label anywhere adds the note, whatever was asked: \(reason)")
    }

    @Test("a label a mask keeps whole, as an exact labels entry does, stays selectable")
    func wholeLabelMaskStaysSelectable() async throws {
        let mask = TreeValueMask(labels: ["Plan"])
        let outcome = try await OutputMasks.$current.withValue(OutputMasks { mask }) {
            try await Assert.parse(["--label", "Plan", "--device", Self.device.rawValue]).evaluate(on: Screen.route, logger: OffsiderLogger())
        }
        #expect(outcome.met)
    }

    @Test("a label a value pattern hides in part matches no label selector")
    func patternMaskedLabel() async throws {
        let tree = FakeUI.tree([FakeUI.node(.text, id: "ticket", label: "Ticket 4410-882", frame: FakeUI.frame(16, 100, 300, 40))])
        let mask = TreeValueMask(patterns: [try NSRegularExpression(pattern: "[0-9]{4}-[0-9]{3}")])
        let message = OutputMasks.$current.withValue(OutputMasks { mask }) { Screen.missMessage(.labelContains("Ticket 44"), roots: tree.roots) }
        #expect(message.contains("select those by --id"), "\(message)")
        #expect(!message.contains("4410"))
    }

    // MARK: Batch

    @Test("a batch's assert steps refuse a password field and miss a masked label, as alone")
    func batchSteps() async throws {
        let backend = FakeDeviceBackend(trees: [Screen.screen()])
        var out = ""
        var err = ""
        let context = BatchContext(
            backend: backend, device: Self.device, axCachePolicy: .perBatch, typeSubmissionMode: .chunked, typeChunkSize: 200,
            waitTimeout: 0, noSettle: true, cachedRecord: nil
        )
        let output = BatchOutput(json: true, write: { out += $0 }, writeError: { err += $0 })
        _ = try? await Screen.masked {
            try await DispatchTracker.$current.withValue(DispatchTracker()) {
                try await Batch.runSteps(
                    ["assert --label-contains Member", "assert --id pin-field --has-value \(Screen.secureText)"],
                    context: context, session: backend.session, continueOnError: true, output: output, logger: OffsiderLogger()
                )
            }
        }
        let records = out.split(separator: "\n").compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
        let reasons = records.compactMap { ($0["error"] as? [String: Any])?["reason"] as? String }
        #expect(reasons.prefix(2) == ["condition_not_met", "secure_field_argument"], "\(out)\(err)")
        #expect(Screen.hidesEverySecret((out + err).replacingOccurrences(of: "--has-value \(Screen.secureText)", with: "")))
    }
}
