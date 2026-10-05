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
        let wait = try Self.command(["--id", "apply", "--gone"])

        let outcome = try await Self.evaluate(wait, on: backend)

        #expect(outcome.met)
        #expect(outcome.reason == "off screen at (20, 10700) 350x44")
        #expect(backend.treeReads == 1)
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
        (["--timeout", "5"], "Choose one of a selector (--id, --label or --value), --settled, --region or --seconds."),
        (["--settled", "--changed"], "--changed and --stable need --region."),
        (["--region", "0,0,10,10"], "--region needs --changed or --stable."),
        (["--region", "0,0,10,10", "--changed", "--stable"], "Use only one of --changed or --stable."),
        (["--settled", "--gone"], "--gone needs --id, --label or --value."),
        (["--seconds", "1", "--settle-by", "screen"], "--settle-by applies to --settled only."),
        (["--id", "a", "--quiet-ms", "200"], "--quiet-ms applies to --settled and --region --stable only."),
        (["--settled", "--quiet-ms", "50"], "--quiet-ms must be from 100 to 10000; got 50."),
        (["--settled", "--quiet-ms", "2000", "--timeout", "1"], "--quiet-ms is longer than --timeout, so the wait could never succeed. Raise --timeout or lower --quiet-ms."),
        (["--id", "a", "--threshold", "0.1"], "--threshold applies to --region only."),
        (["--id", "a", "--timeout", "901"], "--timeout must be from 0 to 900 seconds; got 901.0."),
        (["--seconds", "901"], "--seconds must be from 0 to 900 seconds; got 901.0."),
        (["--id", "a", "--poll-interval", "0.01"], "--poll-interval must be from 0.05 to 5 seconds; got 0.01."),
        (["--id", "a", "--label", "b"], "Use only one of --id, --label, or --value."),
        (["--settled", "--has-value", "3"], "--has-value needs --id, --label or --value."),
    ])
    func rejectsInvalidConditions(arguments: [String], message: String) {
        #expect(Self.validationMessage(arguments) == message)
    }

    @Test("--timeout and --seconds accept up to 900 seconds, for cold bundles that take minutes", arguments: [
        ["--id", "a", "--timeout", "900"],
        ["--seconds", "900"],
    ])
    func acceptsLongWaits(arguments: [String]) {
        #expect(Self.validationMessage(arguments) == nil)
    }
}
