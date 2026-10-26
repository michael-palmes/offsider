import Foundation
import OffsiderCore
import Testing
@testable import Offsider

@Suite("offsider.mask.json labels")
@MainActor
struct MaskFileLabelTests {
    static let config = MaskConfig(ids: ["device-key", "balance"], labelContains: ["Referral code. "])
    static let mask = try! TreeValueMask(plan: config.plan)
    static let secrets = ["rc-5521", "dk-3307", "$12", "$99"]

    /// React Native's copy rows put the value they copy inside the label.
    static func rows(balance: String = "$12", platform: DevicePlatform = .ios, copyRows: Bool = true) -> UITree {
        let copies = copyRows ? [
            FakeUI.node(.button, label: "Referral code. rc-5521. Tap to copy", frame: FakeUI.frame(16, 200, 370, 44), platform: platform),
            FakeUI.node(.button, id: "device-key", label: "Device key. dk-3307. Tap to copy", frame: FakeUI.frame(16, 260, 370, 44), platform: platform),
        ] : []
        return FakeUI.tree(platform: platform, copies + [
            FakeUI.node(.text, id: "balance", label: "Balance", value: balance, frame: FakeUI.frame(16, 320, 370, 30), platform: platform),
            FakeUI.node(.button, id: "back", label: "Back", frame: FakeUI.frame(16, 60, 80, 44), platform: platform),
        ])
    }

    static func leaks(_ text: String) -> Bool {
        secrets.contains { text.contains($0) }
    }

    static func named<T>(_ body: () throws -> T) rethrows -> T {
        try OutputMasks.$current.withValue(OutputMasks { mask }, operation: body)
    }

    static func failure(_ body: () throws -> Void) -> String {
        do {
            try body()
            return ""
        } catch {
            return (error as? LocalizedError)?.errorDescription ?? "\(error)"
        }
    }

    @Test("a labelContains match keeps only the text the file names, an exact label stays whole, an id match hides the label")
    func labelRule() throws {
        let mask = try TreeValueMask(plan: MaskConfig(ids: ["row"], labels: ["Account number"], labelContains: ["Referral code. "]).plan)

        #expect(mask.maskedLabel("Referral code. rc-5521. Tap to copy") == "Referral code. [redacted]")
        #expect(mask.maskedLabel("Copy Referral code. rc-5521") == "[redacted] Referral code. [redacted]")
        #expect(mask.maskedLabel("Account number") == "Account number")
        #expect(mask.maskedLabel("Device key. dk-3307") == "[redacted]")
        #expect(mask.shownLabel("Device key. dk-3307", id: "row") == "[redacted]")
        #expect(mask.shownLabel("Back", id: "back") == "Back")
    }

    @Test("describe-ui text and JSON show a matched row's label masked, and the tree cache never stores it")
    func describeAndCache() async throws {
        let fixture = try TreeCacheFixture()
        let backend = FakeDeviceBackend(trees: [Self.rows()])
        let text = try await fixture.run { try await DescribeUIRedactionTests.describe(["--format", "text"], on: backend, config: Self.config) }
        let json = try await fixture.run { try await DescribeUIRedactionTests.describe([], on: backend, config: Self.config) }

        #expect(text.contains(#"button "Referral code. [redacted]""#))
        #expect(text.contains(#"button "[redacted]" id=device-key"#))
        #expect(text.contains(#"button "Back" id=back"#))
        #expect(text.hasSuffix("# redacted: 3 values\n"))
        #expect(!Self.leaks(text) && !Self.leaks(json))
        let cached = String(decoding: try #require(FileManager.default.contents(atPath: fixture.path(for: DescribeUIRedactionTests.device))), as: UTF8.self)
        #expect(!Self.leaks(cached))
        #expect(cached.contains("Back"))
    }

    @Test("on Android a matched element's content description, hint and state description are hidden too")
    func androidText() throws {
        var node = FakeUI.node(.button, label: "Referral code. rc-5521. Tap to copy", platform: .android)
        node.native = .android(AndroidNativeAttributes(
            text: "Referral code. rc-5521. Tap to copy", contentDescription: "Referral code. rc-5521. Tap to copy",
            hint: "Copies rc-5521", stateDescription: "rc-5521"
        ))
        let shown = UITree(platform: .android, device: "emulator-5554", roots: [node]).redacted(Self.mask).roots[0]

        guard case .android(let attributes) = shown.native else {
            Issue.record("expected Android attributes")
            return
        }
        #expect(shown.label == "Referral code. [redacted]")
        #expect(attributes.contentDescription == "Referral code. [redacted]" && attributes.text == "Referral code. [redacted]")
        #expect(attributes.hint == "[redacted]" && attributes.stateDescription == "[redacted]")
    }

    @Test("a verified tap that removes matched rows lists them masked, in the change list and the summary")
    func verifyChanges() throws {
        let before = Self.rows()
        let after = Self.rows(balance: "$99", copyRows: false)
        let outcome = Verifier.Outcome(verified: true, attempts: 1, change: .accessibilityTree, style: nil, summary: nil)
            .listing(from: before.redacted(Self.mask), to: after.redacted(Self.mask), skipping: [])
        let summary = Self.named {
            ChangeDetector().compare(AccessibilitySnapshot(tree: before, native: false), AccessibilitySnapshot(tree: after, native: false))
        }
        let valueOnly = Self.named {
            ChangeDetector().compare(AccessibilitySnapshot(tree: Self.rows(copyRows: false), native: false), AccessibilitySnapshot(tree: after, native: false))
        }

        #expect(outcome.changes.filter { $0.kind == .removed }.count == 2)
        #expect(!Self.leaks("\(outcome.changes)"))
        guard case .changed(let text) = summary else {
            Issue.record("expected a change, got \(summary)")
            return
        }
        #expect(!Self.leaks(text))
        #expect(valueOnly == .changed(summary: "value of balance changed (masked)"))
    }

    @Test("after an input, --settled holds against a row the cache stored masked, until the screen really changes")
    func settleGateMasksAlike() throws {
        let raw = Self.rows()
        let gate = try #require(SettleGate(sinceInput: 0.1, before: raw.redacted(Self.mask, scope: .cache)))

        Self.named {
            #expect(!gate.showsEffect(in: raw, ignoreValues: false))
            #expect(gate.showsEffect(in: Self.rows(copyRows: false), ignoreValues: false))
        }
    }

    @Test("tap misses name matched rows as describe-ui shows them, in candidate lists and suggestions")
    func resolverMessages() {
        let roots = Self.rows().roots
        let several = Self.named { Self.failure { _ = try AccessibilityTargetResolver.resolveTap(roots: roots, query: .labelContains("Tap to copy")) } }
        let near = Self.named { Self.failure { _ = try AccessibilityTargetResolver.resolveTap(roots: roots, query: .label("Referral code")) } }

        #expect(several.hasPrefix("Multiple (2) accessibility elements matched"))
        #expect(several.contains(#"label="Referral code. [redacted]""#))
        #expect(near.contains(#""Referral code. [redacted]""#))
        #expect(!Self.leaks(several) && !Self.leaks(near))
    }

    @Test("a --has-value miss on a matched element does not print its value")
    func hasValueMiss() async throws {
        let device = DeviceID(rawValue: "fake-device", platform: .ios)
        let command = try Assert.parse(["--id", "balance", "--has-value", "$5", "--device", device.rawValue])
        let route = DeviceRouter.Route(backend: FakeDeviceBackend(trees: [Self.rows()]), device: device)
        let outcome = try await OutputMasks.$current.withValue(OutputMasks { Self.mask }) {
            try await command.evaluate(on: route, logger: OffsiderLogger())
        }

        #expect(!outcome.met)
        #expect(outcome.reason == "has a masked value, expected '$5'")
    }

    @Test("a hidden branch named by a masked descendant's label shows it masked")
    func hiddenBranchLabel() {
        let branch = Self.named {
            UITreeContext.HiddenBranch.shown(id: "drawer", label: "Device key. dk-3307. Tap to copy", labelledBy: "device-key", className: nil, frame: nil)
        }
        #expect(branch.label == "[redacted]")
    }

    @Test("the names a command prints are masked by offsider.mask.json")
    func outputMaskReadsTheFile() {
        let loaded = MaskConfigs.Loaded(config: Self.config, path: "/repo/offsider.mask.json")
        let mask = MaskConfigs.$source.withValue({ loaded }) { AmbientMasks.outputMask() }

        #expect(mask.hides(id: "device-key", label: nil))
        #expect(mask.hides(id: nil, label: "Referral code. rc-5521"))
        #expect(!mask.hides(id: "back", label: "Back"))
    }
}
