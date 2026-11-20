import Foundation
import OffsiderCore
import Testing
@testable import Offsider

/// A mask rule, given on a capture or added to the mask file, tells nothing of text another mask already hides. The text is made up.
@Suite("Mask rules answer no guess about hidden text")
@MainActor
struct MaskGuessTests {
    static let hidden = "kiwi-5150-wren"
    static let device = ScreenshotMaskTests.device

    /// A row whose label copies its children, one of which the file hides by id, and a plain label beside it.
    static func nodes() -> [UINode] {
        [
            FakeUI.node(.button, id: "member-row", label: "Member \(hidden)", frame: FakeUI.frame(20, 100, 350, 60), children: [
                FakeUI.node(.text, label: "Member", frame: FakeUI.frame(20, 100, 150, 30)),
                FakeUI.node(.text, id: "member-code", label: hidden, frame: FakeUI.frame(20, 130, 150, 30)),
            ]),
            FakeUI.node(.text, id: "plan", label: "Plan", frame: FakeUI.frame(20, 300, 350, 30)),
        ]
    }

    static let file = MaskConfig(ids: ["member-code"])

    static func capture(_ arguments: [String], config: MaskConfig = file) async throws -> (report: ScreenshotReport, png: Data) {
        let backend = try ScreenshotMaskTests.backend(Self.nodes())
        let loaded = MaskConfigs.Loaded(config: config, path: "/repo/offsider.mask.json")
        let result = try await MaskConfigs.$source.withValue({ loaded }) {
            try await OutputMasks.$current.withValue(OutputMasks { AmbientMasks.outputMask() }) {
                try await ScreenshotMaskTests.capture(arguments, on: backend, environment: [:])
            }
        }
        defer { try? FileManager.default.removeItem(atPath: result.path) }
        var report = result.report
        report.path = nil
        report.treeReadMs = nil
        report.captureMs = nil
        return (report, try Data(contentsOf: URL(fileURLWithPath: result.path)))
    }

    /// The report with the guess's own text taken out, as it names the flag it was given.
    static func comparable(_ report: ScreenshotReport, guess: String) -> String {
        report.jsonLine().replacingOccurrences(of: guess.replacingOccurrences(of: "\\", with: "\\\\"), with: "<guess>")
    }

    // MARK: Capture flags

    @Test("a capture's text and label flags read the same, in counts, unmatched list and pixels, for a right and a wrong guess at hidden text", arguments: [
        ("--mask-label-contains", "kiwi-5150", "plum-0000"),
        ("--mask-label", hidden, "plum-0000-wren"),
        ("--mask-text", #"kiwi-51\d+"#, #"plum-\d+"#),
        ("--mask-label-contains", "Member kiwi", "Member plum"),
    ])
    func captureFlagsReadAlike(flag: String, right: String, wrong: String) async throws {
        let hit = try await Self.capture([flag, right])
        let miss = try await Self.capture([flag, wrong])

        #expect(Self.comparable(hit.report, guess: right) == Self.comparable(miss.report, guess: wrong))
        #expect(hit.png == miss.png)
    }

    @Test("nothing is painted less than a match on the real text would paint: the hidden element and the row copying it are painted whole")
    func nothingPaintedLess() async throws {
        let result = try await Self.capture(["--mask-label-contains", "kiwi-5150", "--mask-label-contains", "Plan"])
        let image = try ScreenImage.decode(result.png)

        #expect(ScreenshotMaskTests.point(image, 100, 145) == ScreenshotMaskTests.black, "the hidden element")
        #expect(ScreenshotMaskTests.point(image, 300, 110) == ScreenshotMaskTests.black, "the row that copies it")
        #expect(ScreenshotMaskTests.point(image, 100, 315) == ScreenshotMaskTests.black, "a flag on visible text still paints")
        #expect(ScreenshotMaskTests.point(image, 100, 500) == ScreenshotMaskTests.white)
    }

    // MARK: Mask file edits

    static let guessedFiles: [MaskConfig] = [
        MaskConfig(ids: ["member-code"], labelContains: ["kiwi-51"]),
        MaskConfig(ids: ["member-code"], labels: [hidden]),
        MaskConfig(ids: ["member-code"], valuePatterns: [#"kiwi-5\d+"#]),
        MaskConfig(ids: ["member-code"], labelContains: ["Member kiwi"]),
    ]

    @Test("a rule added to the file as a guess changes nothing describe-ui or the tree cache shows", arguments: guessedFiles)
    func fileGuessLeavesTreeAlike(guessed: MaskConfig) throws {
        let tree = FakeUI.tree(width: 390, height: 844, Self.nodes())
        let before = try TreeValueMask(plan: Self.file.plan)
        let after = try TreeValueMask(plan: guessed.plan)

        for scope in [TreeRedactionScope.output, .cache] {
            let shown = tree.redacted(before, scope: scope)
            let guessedShown = tree.redacted(after, scope: scope)
            #expect(shown.roots == guessedShown.roots, "\(scope)")
            #expect(shown.redaction == guessedShown.redaction, "\(scope)")
        }
        let rendered = tree.redacted(after).roots.flatMap { $0.flattened() }.compactMap { [$0.label, $0.value].compactMap { $0 }.joined(separator: " ") }.joined(separator: " ")
        #expect(!rendered.contains("kiwi"), "\(rendered)")
    }

    @Test("a rule added to the file as a guess changes nothing a screenshot reports or paints", arguments: guessedFiles)
    func fileGuessLeavesCaptureAlike(guessed: MaskConfig) async throws {
        let before = try await Self.capture([])
        let after = try await Self.capture([], config: guessed)

        #expect(before.report == after.report)
        #expect(before.png == after.png)
    }

    @Test("a label rule naming a row's visible words still hides the row and every child, though the row copies text an id rule hides")
    func visibleWordsStillHideRow() throws {
        let row = FakeUI.node(.button, id: "referral-row", label: "Referral code. rc-5521. Tap to copy", frame: FakeUI.frame(0, 0, 300, 60), children: [
            FakeUI.node(.text, label: "Referral code.", frame: FakeUI.frame(0, 0, 100, 20)),
            FakeUI.node(.text, id: "code-value", label: "rc-5521", frame: FakeUI.frame(0, 20, 100, 20)),
            FakeUI.node(.text, label: "Tap to copy", frame: FakeUI.frame(0, 40, 100, 20)),
        ])
        let mask = try TreeValueMask(plan: MaskConfig(ids: ["code-value"], labelContains: ["Referral code."]).plan)
        let shown = FakeUI.tree([row]).redacted(mask).roots[0].children[0]
        #expect(shown.label == "[redacted]")
        #expect(shown.children.map(\.label) == ["[redacted]", "[redacted]", "[redacted]"])
    }

    @Test("a hidden toggle's state is not screen text, so a label rule on its row still matches")
    func toggleStateIsNotCopiedText() throws {
        let row = FakeUI.node(.button, label: "Plan 1 of 12", frame: FakeUI.frame(0, 0, 300, 60), children: [
            FakeUI.node(.switch, id: "plan-switch", value: "1", frame: FakeUI.frame(200, 0, 60, 30)),
            FakeUI.node(.text, label: "Renews soon", frame: FakeUI.frame(0, 30, 100, 20)),
        ])
        let mask = try TreeValueMask(plan: MaskConfig(ids: ["plan-switch"], labelContains: ["Plan"]).plan)
        let shown = FakeUI.tree([row]).redacted(mask).roots[0].children[0]
        #expect(shown.children[1].label == "[redacted]", "the row is masked, so its children are too")
    }

    @Test("video refuses alike while a run's mask hides text, whether or not the file guesses at it")
    func videoRunHiddenText() throws {
        let tree = FakeUI.tree(width: 390, height: 844, [FakeUI.node(.text, label: "me@example.com", frame: FakeUI.frame(20, 100, 300, 30))])
        let run = TreeValueMask(emails: true)
        let plain = try VideoMaskOptions.configMatch(MaskConfig(), in: tree, standing: run)
        let guessed = try VideoMaskOptions.configMatch(MaskConfig(valuePatterns: [#"me@exa[a-z]{1,10}\.com"#]), in: tree, standing: run)
        #expect(plain != nil && guessed != nil)
    }

    @Test("video's refusal never names which file rule matched")
    func videoRefusalNamesNoRule() async throws {
        let backend = FakeDeviceBackend(trees: [FakeUI.tree(width: 390, height: 844, Self.nodes())], screen: ScreenshotMaskTests.screen)
        var messages: [String] = []
        for config in [MaskConfig(labelContains: ["Member"]), MaskConfig(labels: ["Member \(Self.hidden)"], labelContains: ["Member"])] {
            let loaded = MaskConfigs.Loaded(config: config, path: "/repo/offsider.mask.json")
            let error = await #expect(throws: CLIError.self) {
                try await MaskConfigs.$source.withValue({ loaded }) {
                    try await VideoMaskOptions.requireNoSecureField(command: "record-video", backend: backend, device: Self.device)
                }
            }
            messages.append(error?.errorDescription ?? "")
        }
        #expect(messages[0] == messages[1], "\(messages)")
        #expect(!messages[1].contains("kiwi"))
    }
}

extension MaskConfig: @retroactive CustomTestStringConvertible {
    public var testDescription: String { "\(ids) \(labels) \(labelContains) \(valuePatterns)" }
}
