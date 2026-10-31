import ArgumentParser
import Foundation
@testable import OffsiderCore
import Testing
@testable import Offsider
@testable import OffsiderAndroid

@Suite("One rule for screen text")
@MainActor
struct OneMaskRuleTests {
    static let device = DeviceID(rawValue: "emulator-5554", platform: .android)
    static let planted = ["$12", "rc-5521"]

    private static func text(_ text: String, id: String? = nil, top: Int) -> RawAndroidNode {
        var attributes = ["class": "android.widget.TextView", "text": text, "bounds": "[16,\(top)][300,\(top + 20)]", "enabled": "true"]
        if let id { attributes["resource-id"] = id }
        return RawAndroidNode(attributes: attributes)
    }

    private static func row(id: String, top: Int, _ children: [RawAndroidNode]) -> RawAndroidNode {
        RawAndroidNode(
            attributes: ["class": "android.view.ViewGroup", "clickable": "true", "resource-id": id, "bounds": "[0,\(top)][400,\(top + 80)]", "enabled": "true"],
            children: children
        )
    }

    /// Two clickable rows with no text of their own, so Android's mapping copies their children's text into their labels.
    static func screen() -> UITree {
        let window = RawAndroidNode(attributes: ["class": "android.widget.FrameLayout", "bounds": "[0,0][400,800]"], children: [
            row(id: "balance-row", top: 100, [text("Balance", top: 100), text("$12", id: "balance", top: 120), text("Details", top: 140)]),
            row(id: "code-row", top: 200, [text("Referral code.", top: 200), text("rc-5521", id: "code-value", top: 220)]),
        ])
        return UITree(platform: .android, device: device.rawValue, roots: [AndroidTreeMapping.node(from: window, scale: 1, rootRole: .application)])
    }

    static let config = MaskConfig(ids: ["balance"], labelContains: ["Referral code."])

    static func backend() -> FakeDeviceBackend {
        FakeDeviceBackend(platform: .android, trees: [screen()])
    }

    /// `body` with `config` bound as the file, and the masks a command's messages read from it.
    static func masked<T>(_ config: MaskConfig = config, _ body: () async throws -> T) async throws -> T {
        let loaded = MaskConfigs.Loaded(config: config, path: "/repo/offsider.mask.json")
        return try await MaskConfigs.$source.withValue({ loaded }) {
            try await OutputMasks.$current.withValue(OutputMasks { AmbientMasks.outputMask() }) {
                try await body()
            }
        }
    }

    static func expectClean(_ text: String, sourceLocation: SourceLocation = #_sourceLocation) {
        for secret in planted {
            #expect(!text.contains(secret), "\(secret) in \(text)", sourceLocation: sourceLocation)
        }
    }

    // MARK: Fixture

    @Test("the fixture is what this suite is about: rows whose mapped labels copy their children's text")
    func mappingCopies() {
        let rows = Self.screen().roots[0].children
        #expect(rows[0].label == "Balance $12 Details")
        #expect(rows[1].label == "Referral code. rc-5521")
    }

    // MARK: The tree

    @Test("a masked child's text is hidden in the clickable parent's copy, on output and in the cache")
    func parentCopyHidden() {
        let mask = TreeValueMask(ids: ["balance"])
        for scope in [TreeRedactionScope.output, .cache] {
            let row = Self.screen().redacted(mask, scope: scope).roots[0].children[0]
            #expect(row.label == "Balance [redacted] Details")
            #expect(row.children[1].label == "[redacted]")
            #expect(row.children[0].label == "Balance" && row.children[2].label == "Details")
        }
    }

    @Test("a masked row's unmatched child is hidden too, and a child naming the file's text keeps it")
    func childOfMaskedHidden() {
        let mask = TreeValueMask(labelContains: ["Referral code."])
        for scope in [TreeRedactionScope.output, .cache] {
            let row = Self.screen().redacted(mask, scope: scope).roots[0].children[1]
            #expect(row.label == "Referral code. [redacted]")
            #expect(row.children[0].label == "Referral code.")
            #expect(row.children[1].label == "[redacted]")
        }
    }

    @Test("a mask on a container hides its children's labels and values")
    func containerHidesChildren() {
        let shown = Self.screen().redacted(TreeValueMask(ids: ["balance-row"])).roots[0].children[0]
        #expect(shown.flattened().allSatisfy { $0.label == "[redacted]" })
        #expect(shown.flattened().count == 4)
    }

    @Test("a mask stops at the app, whose name is not the screen's text")
    func appNameStops() {
        let tree = FakeUI.tree(platform: .android, label: "Playground", [FakeUI.node(.text, label: "Details", platform: .android)])
        let shown = tree.redacted(TreeValueMask(labelContains: ["Playground"])).roots[0]
        #expect(shown.children[0].label == "Details")
    }

    @Test("a hidden text inside a longer one never splits it, whichever is first")
    func longestFirst() {
        let parent = FakeUI.node(.button, label: "12 and 1234", platform: .android, children: [
            FakeUI.node(.text, id: "short", label: "12", platform: .android),
            FakeUI.node(.text, id: "long", label: "1234", platform: .android),
        ])
        let shown = UITree(platform: .android, device: "x", roots: [parent]).redacted(TreeValueMask(ids: ["short", "long"])).roots[0]
        #expect(shown.label == "[redacted] and [redacted]")
    }

    @Test("a revealed field's text is hidden in a parent's copy")
    func revealedCopyHidden() {
        let field = FakeUI.node(.textField, id: "pin", value: "4471", platform: .android)
        let row = FakeUI.node(.button, label: "PIN 4471", platform: .android, children: [field])
        let record = SecureFieldRecord(platform: .android, device: "x", writtenAt: Date(), bootMarker: nil, entries: [.init(id: "pin", frame: nil)])
        let shown = UITree(platform: .android, device: "x", roots: [row]).redacted(TreeValueMask(revealed: RevealedSecrets(record))).roots[0]
        #expect(shown.label == "PIN [redacted]")
        #expect(shown.children[0].value == "••••")
    }

    @Test("nesting costs nothing to count: with no element masks a tree is unchanged and counts nothing")
    func noMasksNoChange() {
        let tree = Self.screen()
        let shown = tree.redacted(.none)
        #expect(shown.roots == tree.roots)
        #expect(shown.redaction == UITreeRedactionCounts())
    }

    @Test("each hidden copy counts once in the footer")
    func counts() {
        #expect(Self.screen().redacted(TreeValueMask(ids: ["balance"])).redaction?.redacted == 2)
    }

    // MARK: Messages

    @Test("after a read, a selector miss names the row and the child as tree output shows them")
    func selectorMissMessages() async throws {
        let fixture = try TreeCacheFixture()
        let messages = try await fixture.run {
            try await Self.masked {
                let roots = try await Self.backend().accessibilityTree(for: Self.device).roots
                let queries: [AccessibilityQuery] = [.labelContains("e"), .label("rc-55"), .label("Referral code. rc")]
                return queries.map { query in
                    MaskFileLabelTests.failure { _ = try AccessibilityTargetResolver.resolveTap(roots: roots, query: query) }
                }
            }
        }
        for message in messages {
            Self.expectClean(message)
        }
        #expect(messages[0].contains("Balance [redacted] Details"), "\(messages[0])")
    }

    @Test("what a cover, a presented view and a page name goes through the same rule")
    func otherNames() async throws {
        let fixture = try TreeCacheFixture()
        try await fixture.run {
            try await Self.masked {
                let tree = try await Self.backend().accessibilityTree(for: Self.device)
                let rows = tree.roots[0].children
                #expect(PresentationProbe.shownLabel(of: rows[0]) == "Balance [redacted] Details")
                #expect(MatchSummary.shownLabel(of: rows[0]) == "Balance [redacted] Details")
                #expect(MatchSummary.shownLabel(of: rows[1].children[1]) == "[redacted]")
                let cover = CoverReport(CoverVerdict(cover: rows[0], evidence: .hitTest, isConfident: true, screen: nil))
                #expect(cover.label == "Balance [redacted] Details")
            }
        }
    }

    @Test("a --has-value miss on a child of a masked row does not print its value")
    func hasValueMissUnderMaskedRow() async throws {
        let field = FakeUI.node(.textField, id: "code-field", value: "rc-5521", frame: FakeUI.frame(0, 100, 300, 40), platform: .android)
        let row = FakeUI.node(.button, id: "secret-row", label: "Row", frame: FakeUI.frame(0, 100, 300, 80), platform: .android, children: [field])
        let backend = FakeDeviceBackend(platform: .android, trees: [FakeUI.tree(platform: .android, device: Self.device.rawValue, [row])])
        let command = try Assert.parse(["--id", "code-field", "--has-value", "nope", "--device", Self.device.rawValue])
        let fixture = try TreeCacheFixture()

        let outcome = try await fixture.run {
            try await Self.masked(MaskConfig(ids: ["secret-row"])) {
                try await command.evaluate(on: DeviceRouter.Route(backend: backend, device: Self.device), logger: OffsiderLogger())
            }
        }

        #expect(outcome.reason == "has a masked value, expected 'nope'")
    }

    // MARK: A planted secret

    /// Every read command's whole output on the fixture.
    private static func everyRead(on route: DeviceRouter.Route) async throws -> [(command: String, output: String)] {
        var outputs: [(String, String)] = []
        func printed(_ run: (Console) async throws -> Void) async -> String {
            let capture = ConsoleCapture()
            try? await run(AgentOutputTests.agentConsole(capture))
            return capture.out + capture.err
        }
        for arguments in [["--format", "text"], ["--format", "json"], ["--on-screen", "--format", "text"]] {
            outputs.append(("describe-ui \(arguments)", try await DescribeUI.parse(arguments + ["--device", device.rawValue]).describe(on: route)))
        }
        for selector in [["--id", "balance"], ["--id", "balance-row"], ["--id", "code-value"], ["--id", "code-row"], ["--id", "balance", "--has-value", "$5"], ["--label", "nothing"]] {
            let assert = try Assert.parse(selector + ["--json", "--device", device.rawValue])
            let outcome = try await assert.evaluate(on: route, logger: OffsiderLogger())
            outputs.append(("assert \(selector)", await printed { try await assert.show(outcome, on: route, console: $0) }))
            let wait = try Wait.parse(selector + ["--json", "--timeout", "0", "--device", device.rawValue])
            let waited = try await wait.evaluate(on: route, logger: OffsiderLogger(), clock: ScriptedClock().poll)
            outputs.append(("wait \(selector)", await printed { try await wait.show(waited, on: route, console: $0) }))
            let step = try await BatchReadResult.redacted(outcome, on: route, success: assert.successLine(outcome), failure: assert.failureLine, checked: assert.selector)
            outputs.append(("batch assert \(selector)", "\(step.detail) \(step.note ?? "") \(step.unmet ?? "")"))
        }
        let roots = try await route.backend.accessibilityTree(for: device).roots
        for query: AccessibilityQuery in [.labelContains("e"), .label("rc-55")] {
            outputs.append(("tap \(query.selectorDescription)", MaskFileLabelTests.failure { _ = try AccessibilityTargetResolver.resolveTap(roots: roots, query: query) }))
        }
        return outputs
    }

    @Test("a planted secret reaches no output of any read command, and the cache never stores it")
    func plantedSecret() async throws {
        let fixture = try TreeCacheFixture()
        let outputs = try await fixture.run {
            try await Self.masked {
                let backend = Self.backend()
                let outputs = try await Self.everyRead(on: DeviceRouter.Route(backend: backend, device: Self.device))
                await TreeCache.commit(command: "describe-ui", effect: .read, claimed: [], backends: [backend])
                return outputs
            }
        }
        let cached = String(decoding: try #require(FileManager.default.contents(atPath: fixture.path(for: Self.device))), as: UTF8.self)
        Self.expectClean(cached)

        #expect(outputs.count > 20)
        for (command, output) in outputs {
            #expect(!output.isEmpty, "\(command) printed nothing")
            for secret in Self.planted {
                #expect(!output.contains(secret), "\(command) printed \(secret): \(output)")
            }
        }
    }

    // MARK: A broken file

    private static let broken: @Sendable () throws -> MaskConfigs.Loaded? = {
        throw CLIError(errorDescription: "offsider.mask.json:3: bad", reason: .usage)
    }

    @Test("a broken mask file stops every command that reads the screen, before it touches a device", arguments: [
        ["assert", "--id", "balance"], ["wait", "--id", "balance"], ["wait", "--settled"], ["tap", "--id", "balance", "--verify"], ["batch", "--step", "assert --id balance"],
        ["describe-ui"], ["type", "hello"],
    ])
    func brokenFileStops(arguments: [String]) async throws {
        var command = try OffsiderCommand.parseAsRoot(arguments + ["--device", "fake-device-not-routed"])
        let error = await #expect(throws: CLIError.self) {
            try await MaskConfigs.$source.withValue(Self.broken) {
                guard var runnable = command as? any AsyncParsableCommand else { throw ExitCode.failure }
                try await runnable.run()
                command = runnable
            }
        }
        #expect(error?.reason == .usage)
        #expect(error?.userFacingDescription.contains("offsider.mask.json") == true)
    }

    @Test("a broken mask file stops the mask a report prints with, rather than unmasking it")
    func brokenFileStopsReport() async throws {
        let route = DeviceRouter.Route(backend: Self.backend(), device: Self.device)
        await #expect(throws: CLIError.self) {
            try await MaskConfigs.$source.withValue(Self.broken) { _ = try await AmbientMasks.shownMask(on: route) }
        }
    }
}
