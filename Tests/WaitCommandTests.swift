import ArgumentParser
import CoreGraphics
import Foundation
import OffsiderCore
import Testing
@testable import Offsider

@Suite("Wait command")
@MainActor
struct WaitCommandTests {
    static let device = DeviceID(rawValue: "fake-device", platform: .ios)

    private static func sheetScreen(applyY: Double) -> UITree {
        FakeUI.tree(width: 393, height: 852, [
            FakeUI.node(.button, id: "apply", label: "Apply", frame: FakeUI.frame(20, applyY, 350, 44)),
        ])
    }

    private static func command(_ arguments: [String]) throws -> Wait {
        try Wait.parse(arguments + ["--device", device.rawValue, "--poll-interval", "0.05"])
    }

    private static func evaluate(_ command: Wait, on backend: FakeDeviceBackend) async throws -> WaitOutcome {
        try await command.evaluate(on: DeviceRouter.Route(backend: backend, device: device), logger: OffsiderLogger(), clock: ScriptedClock().poll)
    }

    private static func validationMessage(_ arguments: [String]) -> String? {
        do {
            _ = try Wait.parse(arguments + ["--device", device.rawValue])
            return nil
        } catch {
            return Wait.message(for: error)
        }
    }

    private static func png(marked: [(x: Int, y: Int)] = []) throws -> Data {
        try ScreenImage.encode(TestImages.make(width: 40, height: 40, marked: marked), as: .png)
    }

    @Test("wait --enabled is met when the button enables, and a timeout says it stayed disabled")
    func waitsForEnabled() async throws {
        let form = { (enabled: Bool) in
            FakeUI.tree(width: 393, height: 852, [FakeUI.node(.button, id: "submit", frame: FakeUI.frame(20, 600, 350, 44), enabled: enabled)])
        }
        let backend = FakeDeviceBackend(trees: [form(false), form(false), form(true)])
        let wait = try Self.command(["--id", "submit", "--enabled", "--timeout", "5"])
        let outcome = try await Self.evaluate(wait, on: backend)
        #expect(outcome.met)
        #expect(outcome.match?.enabled == true)
        #expect(backend.treeReads == 3)
        #expect(wait.successLine(outcome).hasPrefix("✓ --id 'submit' is on screen and enabled after "))

        let stuck = try Self.command(["--id", "submit", "--enabled", "--timeout", "0.2"])
        let timedOut = try await Self.evaluate(stuck, on: FakeDeviceBackend(trees: [form(false)]))
        #expect(!timedOut.met)
        #expect(stuck.failureLine(timedOut).contains("waiting for --id 'submit' to be enabled (last: is disabled, expected enabled)"))
    }

    @Test("wait --id is met once a later tree moves the parked element on screen")
    func waitsForParkedElement() async throws {
        let backend = FakeDeviceBackend(trees: [Self.sheetScreen(applyY: 10700), Self.sheetScreen(applyY: 10700), Self.sheetScreen(applyY: 600)])
        let wait = try Self.command(["--id", "apply", "--timeout", "5"])

        let outcome = try await Self.evaluate(wait, on: backend)

        #expect(outcome.met)
        #expect(outcome.match?.id == "apply")
        #expect(backend.treeReads == 3)
        #expect(wait.successLine(outcome).hasPrefix("✓ --id 'apply' is on screen after "))
    }

    @Test("wait --gone passes when only an off-screen copy is left")
    func goneIgnoresOffScreenCopy() async throws {
        let backend = FakeDeviceBackend(trees: [Self.sheetScreen(applyY: 10700)])
        let wait = try Self.command(["--id", "apply", "--gone", "--stable-for", "0"])

        let outcome = try await Self.evaluate(wait, on: backend)

        #expect(outcome.met)
        #expect(outcome.reason == "off screen at (20, 10700) 350x44")
        #expect(backend.treeReads == 1)

        let dwelling = try await Self.evaluate(try Self.command(["--id", "apply", "--gone"]), on: FakeDeviceBackend(trees: [Self.sheetScreen(applyY: 10700)]))
        #expect(dwelling.met)
        #expect(dwelling.reason == "gone for 0.5 s")
    }

    @Test("a zero-size or frameless match has no usable frame rather than being off screen")
    func zeroSizeMatchHasNoUsableFrame() async throws {
        let screen = FakeUI.tree([
            FakeUI.node(.button, id: "apply", label: "Apply", frame: FakeUI.frame(20, 600, 0, 0)),
            FakeUI.node(.button, id: "apply", label: "Apply"),
        ])
        let backend = FakeDeviceBackend(trees: [screen])
        let wait = try Self.command(["--id", "apply", "--timeout", "0"])

        let outcome = try await Self.evaluate(wait, on: backend)

        #expect(!outcome.met)
        #expect(outcome.reason == "has no usable frame (and 1 more)")
    }

    @Test("a timeout names the selector and the last reason")
    func timeoutLine() async throws {
        let backend = FakeDeviceBackend(trees: [Self.sheetScreen(applyY: 10700)])
        let wait = try Self.command(["--id", "apply", "--timeout", "0"])

        let outcome = try await Self.evaluate(wait, on: backend)

        #expect(!outcome.met)
        #expect(wait.failureLine(outcome) == "✗ Timed out after 0 s waiting for --id 'apply' (last: off screen at (20, 10700) 350x44).")
    }

    @Test("--allow-offscreen counts the parked element as present")
    func allowOffscreenCountsParked() async throws {
        let backend = FakeDeviceBackend(trees: [Self.sheetScreen(applyY: 10700)])
        let wait = try Self.command(["--id", "apply", "--allow-offscreen", "--timeout", "0"])

        let outcome = try await Self.evaluate(wait, on: backend)

        #expect(outcome.met)
        #expect(wait.successLine(outcome).hasPrefix("✓ --id 'apply' is present after "))
    }

    @Test("--label-contains matches the real label and notes when describe-ui shows that part redacted")
    func labelContainsRedacted() async throws {
        let tree = FakeUI.tree(width: 393, height: 852, [FakeUI.node(.text, id: "otp", label: "Your code is 482913", frame: FakeUI.frame(20, 100, 350, 30))])
        let wait = try Self.command(["--label-contains", "482913", "--timeout", "0"])
        let outcome = try await Self.evaluate(wait, on: FakeDeviceBackend(trees: [tree]))

        #expect(outcome.met)
        #expect(Wait.redactionNote(outcome, checked: wait.selector) == " (matched on the real text; describe-ui shows it redacted)")
        #expect(!WaitReport(Wait.shown(outcome)).jsonLine().contains("482913"))

        let plain = try Self.command(["--label-contains", "Your code", "--timeout", "0"])
        let plainOutcome = try await Self.evaluate(plain, on: FakeDeviceBackend(trees: [tree]))
        #expect(Wait.redactionNote(plainOutcome, checked: plain.selector).isEmpty)
    }

    @Test("a timeout prints the report and exits 5")
    func timeoutExitsUnverified() throws {
        let outcome = WaitOutcome(met: false, elapsed: 0, reason: "not found")

        let error = #expect(throws: ExitCode.self) {
            try Wait.report(outcome, success: "", failure: "✗ Timed out", json: true)
        }

        #expect(error?.rawValue == OffsiderExitCode.unverified.rawValue)
    }

    @Test("--region --changed is met when the region's pixels change")
    func regionChanged() async throws {
        let backend = FakeDeviceBackend(
            trees: [],
            screenshots: [try Self.png(), try Self.png(), try Self.png(marked: [(x: 5, y: 5)])],
            screen: UIScreenInfo(width: 20, height: 20, scale: 2, rotation: .portrait)
        )
        let wait = try Self.command(["--region", "0,0,10,10", "--changed", "--timeout", "5"])

        let outcome = try await Self.evaluate(wait, on: backend)

        #expect(outcome.met)
        #expect(backend.screenshotReads == 3)
        #expect(wait.successLine(outcome).hasPrefix("✓ Region changed after "))
    }

    @Test("--region ignores changes outside the region")
    func regionIgnoresOutside() async throws {
        let backend = FakeDeviceBackend(
            trees: [],
            screenshots: [try Self.png(), try Self.png(marked: [(x: 35, y: 35)])],
            screen: UIScreenInfo(width: 20, height: 20, scale: 2, rotation: .portrait)
        )
        let wait = try Self.command(["--region", "0,0,10,10", "--changed", "--timeout", "0.2"])

        let outcome = try await Self.evaluate(wait, on: backend)

        #expect(!outcome.met)
        #expect(outcome.reason == "region unchanged")
        #expect(backend.screenshotReads >= 2)
    }

    @Test("--region on a landscape iOS screen watches the turned capture", arguments: [
        ((x: 30, y: 10), true),
        ((x: 10, y: 10), false),
    ])
    func regionLandscape(change: (x: Int, y: Int), inside: Bool) async throws {
        // Portrait-native 40 x 60 px at 2x; device landscape-left puts logical (5, 5) at physical pixel (30, 10).
        let png = { (marked: [(x: Int, y: Int)]) in try ScreenImage.encode(TestImages.make(width: 40, height: 60, marked: marked), as: .png) }
        let backend = FakeDeviceBackend(
            trees: [],
            screenshots: [try png([]), try png([]), try png([change])],
            screen: UIScreenInfo(width: 30, height: 20, scale: 2, rotation: .landscapeFlipped)
        )
        let wait = try Self.command(["--region", "0,0,10,10", "--changed", "--timeout", inside ? "5" : "0.6"])

        let outcome = try await Self.evaluate(wait, on: backend)

        #expect(outcome.met == inside)
        #expect(backend.screenshotReads >= 3)
    }

    @Test("conflicting or incomplete conditions are rejected", arguments: [
        (["--id", "a", "--settled"], "Choose only one of a selector, --settled, --region or --seconds."),
        (["--timeout", "5"], "Choose one of a selector (--id, --label, --label-contains or --value), --settled, --region or --seconds."),
        (["--id", "a", "--gone", "--disabled"], "--gone does not take --enabled or --disabled."),
        (["--any", "--id", "a", "--id", "b", "--enabled"], "--any does not take --enabled or --disabled."),
        (["--settled", "--enabled"], "--enabled needs --id, --label, --label-contains or --value."),
        (["--settled", "--changed"], "--changed and --stable need --region."),
        (["--region", "0,0,10,10"], "--region needs --changed or --stable."),
        (["--region", "0,0,10,10", "--changed", "--stable"], "Use only one of --changed or --stable."),
        (["--settled", "--gone"], "--gone needs --id, --label, --label-contains or --value."),
        (["--seconds", "1", "--settle-by", "screen"], "--settle-by applies to --settled only."),
        (["--id", "a", "--quiet-ms", "200"], "--quiet-ms applies to --settled and --region --stable only."),
        (["--settled", "--quiet-ms", "50"], "--quiet-ms must be from 100 to 10000; got 50."),
        (["--settled", "--quiet-ms", "2000", "--timeout", "1"], "--quiet-ms is longer than --timeout, so the wait could never succeed. Raise --timeout or lower --quiet-ms."),
        (["--id", "a", "--threshold", "0.1"], "--threshold applies to --region only."),
        (["--id", "a", "--timeout", "901"], "--timeout must be from 0 to 900 seconds; got 901.0."),
        (["--seconds", "901"], "--seconds must be from 0 to 900 seconds; got 901.0."),
        (["--id", "a", "--poll-interval", "0.01"], "--poll-interval must be from 0.05 to 5 seconds; got 0.01."),
        (["--label", "a", "--value", "b"], "Use only one of --id, --label, --label-contains or --value, narrow one --id with a --label, --label-contains or --value, or pass --any to wait for the first of several."),
        (["--id", "a", "--id", "b"], "Use only one of --id, --label, --label-contains or --value, narrow one --id with a --label, --label-contains or --value, or pass --any to wait for the first of several."),
        (["--settled", "--has-value", "3"], "--has-value needs --id, --label, --label-contains or --value."),
        (["--id", "a", "--ignore-values"], "--ignore-values applies to --settled only."),
        (["--settled", "--settle-by", "screen", "--ignore-values"], "--ignore-values reads the accessibility tree, which --settle-by screen does not; use --settle-by tree or both."),
    ])
    func rejectsInvalidConditions(arguments: [String], message: String) {
        #expect(Self.validationMessage(arguments) == message)
    }

    @Test("a --settled timeout where only text moved suggests --ignore-values; with it, or when frames moved, it does not")
    func ignoreValuesHint() throws {
        var outcome = WaitOutcome(met: false, elapsed: 10, reason: "tree still changing")
        outcome.onlyTextMoved = true
        #expect(try Self.command(["--settled"]).failureLine(outcome).hasSuffix("add --ignore-values to let it settle."))
        #expect(!(try Self.command(["--settled", "--ignore-values"]).failureLine(outcome).contains("--ignore-values")))
        outcome.onlyTextMoved = false
        #expect(!(try Self.command(["--settled"]).failureLine(outcome).contains("--ignore-values")))
    }

    @Test("the settle gate comes from this process's own input first, else from the cached record of the last command")
    func settleGateSources() async throws {
        let fixture = try TreeCacheFixture()
        let route = DeviceRouter.Route(backend: FakeDeviceBackend(trees: [Self.sheetScreen(applyY: 600)]), device: Self.device)
        let before = Self.sheetScreen(applyY: 600)
        try await fixture.run {
            #expect(await Wait.settleGate(for: route) == nil)
            try fixture.write(TreeCacheRecord(
                platform: .ios, device: Self.device.rawValue, command: "tap", writtenAt: fixture.now, treeReadAt: fixture.now.addingTimeInterval(-0.4),
                lastInputAt: fixture.now.addingTimeInterval(-0.3), treeRole: .preAction, roots: before.roots
            ))
            let cached = try #require(await Wait.settleGate(for: route))
            #expect(cached.before != nil && abs(cached.sinceInput - 0.3) < 0.001)

            DeviceActivityLedger.current.recordInput(on: Self.device)
            let own = try #require(await Wait.settleGate(for: route))
            #expect(own.before == nil && own.sinceInput == 0)
        }
    }

    @Test("--seconds alone needs no device and touches none; every other wait still needs one")
    func pauseNeedsNoDevice() async throws {
        let pause = try Wait.parse(["--seconds", "1.5"])
        let clock = ScriptedClock()
        let outcome = try await pause.pause(clock: clock.poll)
        #expect(outcome.met)
        #expect(outcome.elapsed == 1.5)

        for arguments in [["--settled"], ["--id", "save"], ["--region", "0,0,10,10", "--stable"]] {
            let message = Wait.message(for: try #require(Self.parsingError(arguments)))
            #expect(message.contains("--device"), "\(arguments)")
        }
    }

    private static func parsingError(_ arguments: [String]) -> (any Error)? {
        do {
            _ = try Wait.parse(arguments)
            return nil
        } catch {
            return error
        }
    }

    @Test("--ignore-id and --ignore-region are checked against the condition", arguments: [
        (["--id", "a", "--ignore-id", "b"], "--ignore-id applies to --settled only"),
        (["--seconds", "1", "--ignore-region", "0,0,10,10"], "--ignore-region applies to --settled only"),
        (["--settled", "--settle-by", "screen", "--ignore-id", "b"], "--ignore-id reads the accessibility tree"),
        (["--settled", "--ignore-region", "0,0,10"], "--ignore-region takes x,y,width,height"),
        (["--settled", "--ignore-region", "0,0,0,10"], "--ignore-region 0,0,0,10 has no area"),
    ])
    func ignoreFlagsAreChecked(arguments: [String], expected: String) {
        let message = Self.validationMessage(arguments)
        #expect(message?.contains(expected) == true, "\(message ?? "accepted")")
    }

    private static func chart(_ y: Double) -> UITree {
        FakeUI.tree(width: 393, height: 852, [
            FakeUI.node(.other, id: "chart", frame: FakeUI.frame(20, y, 300, 200)),
            FakeUI.node(.button, id: "save", label: "Save", frame: FakeUI.frame(20, 600, 350, 44)),
        ])
    }

    @Test("a settle that times out on a moving group prints the flag that leaves it out, and that flag settles it")
    func timeoutNamesTheFlag() async throws {
        let backend = FakeDeviceBackend(trees: (0..<60).map { Self.chart(Double(100 + $0)) })
        let stuck = try Self.command(["--settled", "--ignore-values", "--timeout", "1"])
        let outcome = try await Self.evaluate(stuck, on: backend)
        #expect(!outcome.met)
        #expect(stuck.failureLine(outcome).contains("add --ignore-id chart to leave it out."))
        let details = stuck.personOutcome(Wait.shown(outcome), note: nil).details
        #expect(details.contains("Part of it keeps moving; --ignore-id chart leaves it out"))
        let json = try #require(try JSONSerialization.jsonObject(with: Data(WaitReport(outcome).jsonLine().utf8)) as? [String: Any])
        #expect(json["leaveOut"] as? String == "--ignore-id chart")

        let settled = try Self.command(["--settled", "--ignore-values", "--ignore-id", "chart", "--timeout", "1"])
        #expect(try await Self.evaluate(settled, on: FakeDeviceBackend(trees: (0..<60).map { Self.chart(Double(100 + $0)) })).met)
    }

    @Test("a left-out region's and id's pixels do not count, with --settle-by both")
    func leftOutPixels() async throws {
        let moving = try (0..<20).map { try Self.png(marked: [(x: 2 + $0 % 8, y: 2)]) }
        let screen = UIScreenInfo(width: 40, height: 40, scale: 1, rotationDegrees: 0)
        let frameID = FakeUI.tree(width: 40, height: 40, [FakeUI.node(.other, id: "chart", frame: FakeUI.frame(0, 0, 20, 10)), FakeUI.node(.button, id: "save", frame: FakeUI.frame(0, 20, 40, 20))])

        let plain = FakeDeviceBackend(trees: [frameID], screenshots: moving, screen: screen)
        #expect(try await Self.evaluate(try Self.command(["--settled", "--settle-by", "both", "--timeout", "1"]), on: plain).met == false)

        let byRegion = FakeDeviceBackend(trees: [frameID], screenshots: moving, screen: screen)
        #expect(try await Self.evaluate(try Self.command(["--settled", "--settle-by", "both", "--ignore-region", "0,0,20,10", "--timeout", "1"]), on: byRegion).met)

        let byID = FakeDeviceBackend(trees: [frameID], screenshots: moving, screen: screen)
        #expect(try await Self.evaluate(try Self.command(["--settled", "--settle-by", "both", "--ignore-id", "chart", "--timeout", "1"]), on: byID).met)
    }

    @Test("the draw hold is for Android after an input, and an explicit --settle-by turns it off", arguments: [
        (DevicePlatform.android, ["--settled"], true, true),
        (.android, ["--settled"], false, false),
        (.ios, ["--settled"], true, false),
        (.android, ["--settled", "--settle-by", "tree"], true, false),
        (.android, ["--settled", "--settle-by", "both"], true, false),
    ])
    func drawHoldScope(platform: DevicePlatform, arguments: [String], afterInput: Bool, holds: Bool) throws {
        let gate = afterInput ? SettleGate(sinceInput: 0.1, before: nil) : nil
        let condition = try Self.command(arguments).condition(gate: gate, platform: platform)
        guard case .settled(_, _, _, _, _, let drawHold) = condition else {
            Issue.record("not a settled condition")
            return
        }
        #expect((drawHold != nil) == holds)
    }

    @Test("--timeout and --seconds accept up to 900 seconds, for cold bundles that take minutes", arguments: [
        ["--id", "a", "--timeout", "900"],
        ["--seconds", "900"],
    ])
    func acceptsLongWaits(arguments: [String]) {
        #expect(Self.validationMessage(arguments) == nil)
    }

    @Test("--stable-for is checked against the condition and --timeout", arguments: [
        (["--settled", "--stable-for", "500"], "use --quiet-ms"),
        (["--region", "0,0,10,10", "--stable", "--stable-for", "500"], "use --quiet-ms"),
        (["--seconds", "1", "--stable-for", "500"], "--stable-for needs --id, --label, --label-contains or --value"),
        (["--id", "x", "--stable-for", "60001"], "--stable-for must be from 0 to 60000"),
        (["--id", "x", "--gone", "--timeout", "1", "--stable-for", "1500"], "--stable-for is longer than --timeout"),
    ])
    func stableForValidation(arguments: [String], message: String) {
        #expect(Self.validationMessage(arguments)?.contains(message) == true, "\(Self.validationMessage(arguments) ?? "no error")")
    }

    @Test("--gone holds 500 ms by default, none at --timeout 0, and --stable-for overrides it")
    func goneDefaultDwell() throws {
        #expect(try Self.command(["--id", "x", "--gone"]).stableFor == 0.5)
        #expect(try Self.command(["--id", "x", "--gone", "--timeout", "0"]).stableFor == 0)
        #expect(try Self.command(["--id", "x", "--gone", "--stable-for", "0"]).stableFor == 0)
        #expect(try Self.command(["--id", "x"]).stableFor == 0)
        #expect(try Self.command(["--id", "x", "--stable-for", "300"]).stableFor == 0.3)
    }
}

@Suite("wait --any")
@MainActor
struct WaitAnyTests {
    static let device = DeviceID(rawValue: "fake-device", platform: .ios)

    static func screen(_ ids: [String]) -> UITree {
        FakeUI.tree(width: 393, height: 852, ids.enumerated().map { index, id in
            FakeUI.node(.button, id: id, label: id.capitalized, frame: FakeUI.frame(20, 100 + Double(index) * 60, 350, 44))
        })
    }

    static func evaluate(_ arguments: [String], trees: [UITree]) async throws -> (Wait, WaitOutcome) {
        let wait = try Wait.parse(arguments + ["--device", device.rawValue, "--poll-interval", "0.05"])
        let outcome = try await wait.evaluate(on: DeviceRouter.Route(backend: FakeDeviceBackend(trees: trees), device: device), logger: OffsiderLogger(), clock: ScriptedClock().poll)
        return (wait, outcome)
    }

    @Test("the first selector on screen wins, in order ids, labels, values, and the report names it")
    func firstPresentWins() async throws {
        let (wait, outcome) = try await Self.evaluate(["--any", "--id", "never-there", "--id", "done", "--label", "Retry"], trees: [Self.screen([]), Self.screen(["retry", "done"])])

        #expect(outcome.met)
        #expect(outcome.matched == WaitMatch(by: "id", text: "done", position: 2, of: 3))
        #expect(wait.successLine(outcome).hasPrefix("✓ --id 'done' is on screen after "))
        #expect(wait.successLine(outcome).hasSuffix("(2 of 3 selectors)"))
        let json = WaitReport(outcome).jsonLine()
        #expect(json.contains(#""matched":{"by":"id","text":"done"}"#))
        #expect(json.range(of: #""match":"#)!.lowerBound < json.range(of: #""matched":"#)!.lowerBound)
    }

    @Test("a timeout names each selector's last reason")
    func timeoutReasons() async throws {
        let (wait, outcome) = try await Self.evaluate(["--any", "--id", "a", "--label", "B", "--timeout", "0.2"], trees: [Self.screen([])])

        #expect(!outcome.met)
        #expect(outcome.reason == "--id 'a' not found; --label 'B' not found")
        #expect(wait.failureLine(outcome).contains("any of --id 'a', --label 'B'"))
        #expect(WaitReport(outcome).jsonLine().contains(#""matched":null"#))
    }

    @Test("--any with one selector is a plain wait for it, reported and met as one without --any")
    func oneSelectorIsAPlainWait() async throws {
        let trees = [Self.screen([]), Self.screen(["done"])]
        let (any, met) = try await Self.evaluate(["--any", "--label", "Done"], trees: trees)
        let (plain, expected) = try await Self.evaluate(["--label", "Done"], trees: trees)

        #expect(met.met)
        #expect(met.matched == expected.matched)
        #expect(WaitReport(met).jsonLine() == WaitReport(expected).jsonLine())
        #expect(any.successLine(met) == plain.successLine(expected))
        let (_, gone) = try await Self.evaluate(["--any", "--id", "done", "--gone", "--stable-for", "0"], trees: [Self.screen(["done"]), Self.screen([])])
        #expect(gone.met)
    }

    @Test("--any refuses --gone and --has-value with several selectors; several selectors need --any", arguments: [
        (["--any"], "Choose one of a selector"),
        (["--any", "--id", "a", "--id", "b", "--gone"], "does not take --gone"),
        (["--any", "--id", "a", "--id", "b", "--has-value", "1"], "does not take --has-value"),
        (["--label", "a", "--label", "b"], "pass --any"),
    ])
    func validation(arguments: [String], message: String) {
        let error = #expect(throws: (any Error).self) { try Wait.parse(arguments + ["--device", Self.device.rawValue]) }
        #expect(error.map { Wait.message(for: $0).contains(message) } == true, "\(error.map { Wait.message(for: $0) } ?? "")")
    }

    @Test("assert takes one selector, or one --id narrowed by a label or value", arguments: [["--id", "a", "--id", "b"], ["--label", "a", "--value", "b"]])
    func assertTakesOne(arguments: [String]) {
        let error = #expect(throws: (any Error).self) { try Assert.parse(arguments + ["--device", Self.device.rawValue]) }
        #expect(error.map { Assert.message(for: $0) } == SelectorQuery.refinementRule)
        #expect(throws: Never.self) { try Assert.parse(["--id", "a", "--label", "b", "--value", "c", "--device", Self.device.rawValue]) }
    }
}
