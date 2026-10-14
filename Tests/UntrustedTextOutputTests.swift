import ArgumentParser
import Foundation
import OffsiderCore
import Testing
@testable import Offsider

/// Screen text is data from the app under test: every output path shows it escaped, one element per line.
@Suite("Untrusted text output")
@MainActor
struct UntrustedTextOutputTests {
    static let device = DeviceID(rawValue: "fake-device", platform: .ios)

    static let hostile = [
        "Sign in\u{1B}]52;c;ZXZpbA==\u{07}",
        "Pay\u{202E}moc.elpmaxe",
        "Line one\nError: forged",
        "Tag\u{E0041}\u{E0042}",
        "Clear\u{1B}[2J\u{1B}[H",
        "Zero\u{200B}width\u{2028}sep",
    ]

    /// The same text with each hazard replaced by a letter, so it renders in the same shape.
    static func defanged(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.map { TerminalText.isHazard($0) ? "x" : $0 }))
    }

    static func tree(_ labels: [String], root: String = "App\u{1B}]0;pwned\u{07}", value: String = "v\u{1B}[31m") -> UITree {
        FakeUI.tree(label: root, labels.enumerated().map { index, label in
            FakeUI.node(.button, id: "b\(index)", label: label, value: index == 0 ? value : nil, frame: FakeUI.frame(20, 100 + Double(index) * 60, 350, 44))
        })
    }

    static let cleanTree = tree(hostile.map(defanged), root: defanged("App\u{1B}]0;pwned\u{07}"), value: defanged("v\u{1B}[31m"))

    /// No escape, bell or other hazard scalar survives; only the newlines between lines remain.
    static func expectInert(_ output: String, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(!output.utf8.contains(0x1B), sourceLocation: sourceLocation)
        #expect(!output.utf8.contains(0x07), sourceLocation: sourceLocation)
        let raw = output.unicodeScalars.filter { TerminalText.isHazard($0) && $0 != "\n" }
        #expect(raw.isEmpty, "raw hazards: \(raw.map { String($0.value, radix: 16) })", sourceLocation: sourceLocation)
    }

    static func lines(_ output: String) -> Int {
        output.split(separator: "\n", omittingEmptySubsequences: false).count
    }

    private static func describe(_ arguments: [String], on backend: FakeDeviceBackend) async throws -> String {
        let output = try await DescribeUI.parse(arguments + ["--device", device.rawValue]).describe(on: DeviceRouter.Route(backend: backend, device: device))
        await TreeCache.commit(command: "describe-ui", effect: .read, claimed: [], backends: [backend])
        DeviceActivityLedger.current.reset()
        return output
    }

    @Test("describe-ui --summary escapes screen text and prints one line per element, as a clean tree does")
    func summary() async throws {
        let fixture = try TreeCacheFixture()
        let hostile = try await fixture.run { try await Self.describe(["--summary"], on: FakeDeviceBackend(trees: [Self.tree(Self.hostile)])) }
        let clean = try await fixture.run { try await Self.describe(["--summary"], on: FakeDeviceBackend(trees: [Self.cleanTree])) }
        Self.expectInert(hostile)
        #expect(Self.lines(hostile) == Self.lines(clean))
        #expect(hostile.contains(#""Line one\nError: forged""#))
        #expect(hostile.contains(#""Sign in\u001b]52;c;ZXZpbA==\u0007""#))
    }

    @Test("describe-ui JSON escapes hazards and decodes back to the original labels")
    func json() async throws {
        let fixture = try TreeCacheFixture()
        let output = try await fixture.run { try await Self.describe(["--flat"], on: FakeDeviceBackend(trees: [Self.tree(Self.hostile)])) }
        Self.expectInert(output)
        let object = try #require(try JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
        let nodes = try #require(object["nodes"] as? [[String: Any]])
        #expect(nodes.compactMap { $0["label"] as? String }.dropFirst().elementsEqual(Self.hostile))
        #expect(nodes.first?["label"] as? String == "App\u{1B}]0;pwned\u{07}")
        #expect(nodes.dropFirst().first?["value"] as? String == "v\u{1B}[31m")
    }

    @Test("describe-ui --diff escapes old and new text and keeps the clean tree's line count")
    func diff() async throws {
        func run(_ first: UITree, _ second: UITree) async throws -> String {
            let fixture = try TreeCacheFixture()
            let backend = FakeDeviceBackend(trees: [first, second])
            return try await fixture.run {
                _ = try await Self.describe(["--summary"], on: backend)
                fixture.now += 1
                return try await Self.describe(["--diff"], on: backend)
            }
        }
        let changed = Self.hostile.map { $0 + "\u{1B}[5m!" }
        let hostile = try await run(Self.tree(Self.hostile), Self.tree(changed))
        let clean = try await run(Self.cleanTree, Self.tree(changed.map(Self.defanged), root: Self.defanged("App\u{1B}]0;pwned\u{07}"), value: Self.defanged("v\u{1B}[31m")))
        Self.expectInert(hostile)
        #expect(Self.lines(hostile) == Self.lines(clean))
    }

    @Test("a batch's describe-ui step and a failed step's message stay inert")
    func batchStep() async throws {
        let backend = FakeDeviceBackend(trees: [Self.tree(Self.hostile)])
        let context = BatchContext(backend: backend, device: Self.device, axCachePolicy: .perBatch, typeSubmissionMode: .chunked, typeChunkSize: 200)
        var written = ""
        var errors = ""
        let output = BatchOutput(json: false, write: { written += $0 }, writeError: { errors += $0 })
        var message = ""
        do {
            _ = try await Batch.runSteps(
                ["describe-ui --summary", "tap --label 'Sign in'"], context: context, session: backend.session,
                continueOnError: true, output: output, logger: OffsiderLogger()
            )
        } catch {
            message = OffsiderCommand.message(for: error)
        }
        Self.expectInert(written)
        Self.expectInert(errors)
        #expect(message.contains("Step 2 failed"))
        let text = ErrorReporter.errorText(message)
        Self.expectInert(text)
        #expect(text.split(separator: "\n").allSatisfy { $0.hasPrefix("Error: ") || $0.hasPrefix(" ") })
        #expect(written.split(separator: "\n").count == 1 + Self.hostile.count + 1)
    }

    @Test("a tap --label miss names the near match escaped, on one Error line, and its JSON candidates decode to the original")
    func tapMiss() async throws {
        let backend = FakeDeviceBackend(trees: [Self.tree(Self.hostile)])
        let error = await #expect(throws: (any Error).self) {
            try await Tap.parse(["--label", "Sign in", "--no-settle", "--device", Self.device.rawValue])
                .execute(on: DeviceRouter.Route(backend: backend, device: Self.device), progress: nil, logger: OffsiderLogger())
        }
        let failure = try #require(error)
        let text = ErrorReporter.errorText(OffsiderCommand.message(for: failure))
        Self.expectInert(text)
        #expect(text.hasPrefix("Error: "))
        #expect(!text.dropLast().contains("\n"))
        #expect(text.contains(#"Sign in\u001b]52;c;ZXZpbA==\u0007"#))

        let envelope = ErrorEnvelope(command: "tap", error: ErrorReporter.payload(for: failure)).jsonLine()
        Self.expectInert(envelope)
        let object = try #require(try JSONSerialization.jsonObject(with: Data(envelope.utf8)) as? [String: Any])
        let candidates = try #require((object["error"] as? [String: Any])?["candidates"] as? [[String: Any]])
        #expect(candidates.contains { $0["label"] as? String == Self.hostile[0] })
    }

    @Test("a tap --verify report names changed hostile text escaped on one line")
    func tapVerify() throws {
        let before = Self.tree(Self.hostile)
        let after = Self.tree(Self.hostile.map { $0 + "\u{1B}[5m!" })
        let diff = TreeDiff.diff(old: before, new: after).cappedChanges()
        let summary: String? = switch ChangeDetector().compare(AccessibilitySnapshot(tree: before), AccessibilitySnapshot(tree: after)) {
        case .changed(let summary): summary
        default: nil
        }
        let request = VerifyRequest(
            command: "tap", subject: "Tap on id=b0", target: "id=b0",
            backend: FakeDeviceBackend(trees: []), device: Self.device,
            options: try VerificationOptions.parse(["--verify"]), styles: [.physical], targetNode: nil
        )
        var outcome = Verifier.Outcome(verified: true, attempts: 1, change: .accessibilityTree, style: .physical, summary: summary)
        outcome.changes = diff.changes
        let line = VerifyOutput.verifiedLine(outcome, for: request)
        Self.expectInert(line)
        #expect(!line.contains("\n"))
        #expect(summary.map { !$0.utf8.contains(0x1B) } == true)
    }

    @Test("a window title, presented process and hidden branch with hazards are quoted on their own header line; clean ones print as before")
    func headerLines() {
        let context = UITreeContext(
            window: .init(title: "Lab\u{1B}]0;x\u{07}\nToggles", kind: .modal, package: nil),
            presented: .init(label: "Cancel", role: .button, process: "Picker\u{202E}"),
            hidden: 1, hiddenBranches: [.init(id: nil, label: nil, className: "a.b.Drawer\u{1B}[2J", frame: nil)]
        )
        let lines = context.headerLines
        #expect(lines.count == 3)
        lines.forEach { Self.expectInert($0) }
        #expect(lines[0] == #"# window: "Lab\u001b]0;x\u0007\nToggles" (modal)"#)
        #expect(UITreeContext(window: .init(title: "Lab Toggles", kind: .modal, package: nil)).headerLines == ["# window: Lab Toggles (modal)"])
    }
}
