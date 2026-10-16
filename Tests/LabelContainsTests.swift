import ArgumentParser
import CoreGraphics
import Foundation
import OffsiderCore
import Testing
@testable import Offsider

/// `--label-contains` across commands, and the near misses a wait or assert names when a selector finds nothing.
@Suite("Label contains and near misses", .personOutput)
@MainActor
struct LabelContainsTests {
    static let device = DeviceID(rawValue: "fake-device", platform: .ios)
    static let merged = "Choose a layout. Rows can show as a list or a grid, and the grid holds up to four columns."

    /// A React Native bottom sheet whose heading and detail text are merged into one header.
    static func sheet() -> UITree {
        FakeUI.tree(width: 393, height: 852, [
            FakeUI.node(.header, id: "layout-sheet-title", label: merged, frame: FakeUI.frame(16, 500, 361, 60)),
            FakeUI.node(.button, id: "layout-done", label: "Done", frame: FakeUI.frame(16, 700, 361, 44)),
        ])
    }

    static func wait(_ arguments: [String], trees: [UITree]? = nil) async throws -> (Wait, WaitOutcome) {
        let wait = try Wait.parse(arguments + ["--device", device.rawValue, "--poll-interval", "0.05"])
        let route = DeviceRouter.Route(backend: FakeDeviceBackend(trees: trees ?? [sheet()]), device: device)
        return (wait, try await wait.evaluate(on: route, logger: OffsiderLogger(), clock: ScriptedClock().poll))
    }

    static func assert(_ arguments: [String]) async throws -> (Assert, WaitOutcome) {
        let command = try Assert.parse(arguments + ["--device", device.rawValue])
        let route = DeviceRouter.Route(backend: FakeDeviceBackend(trees: [sheet()]), device: device)
        return (command, try await command.evaluate(on: route, logger: OffsiderLogger()))
    }

    static func nearest(_ outcome: WaitOutcome) throws -> [[String: Any]] {
        let object = try #require(try JSONSerialization.jsonObject(with: Data(WaitReport(outcome).jsonLine().utf8)) as? [String: Any])
        return try #require(object["nearest"] as? [[String: Any]])
    }

    // MARK: wait and assert

    @Test("wait --label-contains is met by a merged label, in the same case only")
    func waitLabelContains() async throws {
        let (wait, met) = try await Self.wait(["--label-contains", "Choose a layout", "--timeout", "1"])
        #expect(met.met)
        #expect(met.match?.id == "layout-sheet-title")
        #expect(wait.successLine(met).hasPrefix("✓ --label-contains 'Choose a layout' is on screen after "))

        let (_, lowercase) = try await Self.wait(["--label-contains", "choose a layout", "--timeout", "0"])
        #expect(!lowercase.met)
    }

    @Test("a --label wait that times out beside a merged label names it as the nearest, with the --label-contains to use")
    func waitNamesNearest() async throws {
        let (wait, outcome) = try await Self.wait(["--label", "Choose a layout", "--timeout", "0.2"])

        #expect(!outcome.met)
        #expect(outcome.reason == "not found")
        #expect(wait.failureLine(outcome) == "✗ Timed out after 0.2 s waiting for --label 'Choose a layout' (last: not found; nearest: header \"Choose a layout. Rows can show as a list or…\" starts with it, use --label-contains \"Choose a layout\").")
        let nearest = try Self.nearest(outcome)
        #expect(nearest.count == 1)
        #expect(nearest.first?["id"] as? String == "layout-sheet-title")
        #expect(nearest.first?["role"] as? String == "header")
        #expect(nearest.first?["closeness"] as? String == "prefix")
        #expect(nearest.first?["onScreen"] as? Bool == true)
    }

    @Test("an iOS wait that times out while the LogBox inspector is open still names the nearest element")
    func waitNamesNearestBesideInspector() async throws {
        let roots = Self.sheet().roots + LogBoxTrees.inspector()
        let tree = FakeUI.tree(width: 393, height: 852, roots)
        let (wait, outcome) = try await Self.wait(["--label", "Choose a layout", "--timeout", "0.2"], trees: [tree])

        #expect(outcome.reason == "not found; LogBox inspector open")
        #expect(wait.failureLine(outcome).contains("nearest: header \"Choose a layout. Rows can show as a list or…\" starts with it"))
        #expect(try Self.nearest(outcome).first?["id"] as? String == "layout-sheet-title")
    }

    @Test("a typo is named with the exact selector to use, and a miss with nothing close names none")
    func nearestForTypoAndNothing() async throws {
        let (wait, typo) = try await Self.wait(["--label", "Dome", "--timeout", "0"])
        #expect(wait.failureLine(typo).contains("(last: not found; nearest: button \"Done\" is close, use --label \"Done\")"))
        #expect(try Self.nearest(typo).first?["closeness"] as? String == "similar")

        let (other, nothing) = try await Self.wait(["--id", "settings-tab", "--timeout", "0"])
        #expect(nothing.nearMiss == nil)
        #expect(other.failureLine(nothing) == "✗ Timed out after 0 s waiting for --id 'settings-tab' (last: not found).")
        #expect(try Self.nearest(nothing).isEmpty)
    }

    @Test("wait --any names the nearest of each selector that found nothing")
    func anyNamesEachMiss() async throws {
        let (wait, outcome) = try await Self.wait(["--any", "--label", "Choose a layout", "--label-contains", "Dome", "--timeout", "0"])

        #expect(outcome.reason == "--label 'Choose a layout' not found; --label-contains 'Dome' not found")
        #expect(wait.failureLine(outcome).contains("nearest: --label 'Choose a layout': header \"Choose a layout. Rows can show as a list or…\" starts with it, use --label-contains \"Choose a layout\"; --label-contains 'Dome': button \"Done\" is close, use --label \"Done\")"))
        #expect(try Self.nearest(outcome).compactMap { $0["id"] as? String } == ["layout-sheet-title", "layout-done"])

        let (_, met) = try await Self.wait(["--any", "--label", "Nope", "--label-contains", "list or a grid", "--timeout", "0"])
        #expect(met.matched == WaitMatch(by: "label-contains", text: "list or a grid", position: 2, of: 2))
    }

    @Test("assert --label names the nearest on a miss, and assert --label-contains passes")
    func assertNamesNearest() async throws {
        let (command, missed) = try await Self.assert(["--label", "Choose a layout"])
        #expect(command.failureLine(missed) == "✗ Assertion failed: --label 'Choose a layout' was not found (nearest: header \"Choose a layout. Rows can show as a list or…\" starts with it, use --label-contains \"Choose a layout\").")

        let (passing, met) = try await Self.assert(["--label-contains", "as a list"])
        #expect(met.met)
        #expect(passing.successLine(met) == "✓ --label-contains 'as a list' is on screen")
    }

    @Test("--label-contains narrows an --id for wait and assert")
    func refinesID() async throws {
        let (_, met) = try await Self.wait(["--id", "layout-sheet-title", "--label-contains", "list or a grid", "--timeout", "0"])
        #expect(met.met)

        let (command, missed) = try await Self.assert(["--id", "layout-sheet-title", "--label-contains", "Colour"])
        #expect(!missed.met)
        #expect(command.failureLine(missed) == "✗ Assertion failed: --id 'layout-sheet-title' --label-contains 'Colour' was not found.")
    }

    // MARK: The wait loop

    private final class Reads {
        var trees = 0
        var explained: [UITree] = []
    }

    private static func sources(_ trees: [UITree], reads: Reads) -> WaitSources {
        let clock = ScriptedClock()
        return WaitSources(
            tree: {
                defer { reads.trees += 1 }
                return trees[min(reads.trees, trees.count - 1)]
            },
            fingerprint: { throw CLIError(errorDescription: "no screen") },
            sleep: { try await clock.poll.sleep($0) },
            now: { clock.now }
        )
    }

    @Test("the loop works out a near miss once, from the last tree, only when the last read found nothing")
    func explainsOnceFromLastTree() async throws {
        let first = FakeUI.tree([FakeUI.node(.text, label: "Loading", frame: FakeUI.frame(0, 0, 100, 20))])
        let last = Self.sheet()
        let reads = Reads()
        let probe: (UITree) -> ElementProbe = { _ in .absent(reason: ElementProbe.notFound) }
        let explain: (UITree) -> WaitNearMiss? = { tree in
            reads.explained.append(tree)
            return WaitNearMiss(summary: "close", candidates: [])
        }

        let outcome = try await WaitLoop.run(.element(probe: probe, gone: false, explain: explain), timeout: 1, interval: 0.25, sources: Self.sources([first, first, last], reads: reads))

        #expect(reads.trees == 5)
        #expect(reads.explained == [last])
        #expect(outcome.nearMiss?.summary == "close")

        let offScreen = Reads()
        let parked: (UITree) -> ElementProbe = { _ in .absent(reason: "off screen at (16, 10500) 361x60") }
        let explainParked: (UITree) -> WaitNearMiss? = { tree in
            offScreen.explained.append(tree)
            return nil
        }
        let held = try await WaitLoop.run(.element(probe: parked, gone: false, explain: explainParked), timeout: 0.5, interval: 0.25, sources: Self.sources([last], reads: offScreen))
        #expect(offScreen.explained.isEmpty)
        #expect(held.nearMiss == nil)
    }

    // MARK: Other commands

    @Test("--label and --label-contains together are refused outside wait --any", arguments: [
        ["wait", "--label", "a", "--label-contains", "b"],
        ["wait", "--id", "x", "--label", "a", "--label-contains", "b"],
        ["assert", "--label", "a", "--label-contains", "b"],
        ["tap", "--label", "a", "--label-contains", "b"],
    ])
    func refusesBothLabelSelectors(arguments: [String]) {
        let error = #expect(throws: (any Error).self) { _ = try OffsiderCommand.parseAsRoot(arguments + ["--device", Self.device.rawValue]) }
        #expect(error.map { OffsiderCommand.message(for: $0) } == SelectorQuery.oneLabelRule)
    }

    @Test("slider and type take --label-contains in place of a label, never beside one")
    func sliderAndType() throws {
        #expect(throws: (any Error).self) { _ = try Slider.parse(["--label", "a", "--label-contains", "b", "--value", "5", "--device", Self.device.rawValue]) }
        #expect(throws: (any Error).self) { _ = try Type.parse(["hi", "--into-label", "a", "--into-label-contains", "b", "--device", Self.device.rawValue]) }
        let type = try Type.parse(["hi", "--into-label-contains", "Email", "--device", Self.device.rawValue])
        #expect(type.intoQuery?.selectorDescription == "--label-contains 'Email'")
    }

    @Test("tap --label-contains taps the element whose label holds the text")
    func tapLabelContains() async throws {
        let backend = FakeDeviceBackend(trees: [Self.sheet()])
        let tap = try Tap.parse(["--label-contains", "list or a grid", "--no-settle", "--device", Self.device.rawValue])

        try await tap.execute(on: DeviceRouter.Route(backend: backend, device: Self.device), progress: nil, logger: OffsiderLogger())

        #expect(backend.session.calls == [.perform(.tapAt(x: 196.5, y: 530))])
    }

    @Test("a batch tap step keeps the --label-contains that narrows its --id, and a batch wait step meets it")
    func batchSteps() async throws {
        let rows = FakeUI.tree([
            FakeUI.node(.button, id: "row", label: "Wi-Fi, on", frame: FakeUI.frame(20, 100, 350, 44)),
            FakeUI.node(.button, id: "row", label: "Bluetooth, off", frame: FakeUI.frame(20, 300, 350, 44)),
        ])
        let backend = FakeDeviceBackend(trees: [rows])
        let context = BatchContext(backend: backend, device: Self.device, axCachePolicy: .perBatch, typeSubmissionMode: .chunked, typeChunkSize: 200, noSettle: true)
        var out = ""
        let output = BatchOutput(json: true, write: { out += $0 }, writeError: { _ in })

        try await Batch.runSteps(
            ["wait --label-contains Bluetooth --timeout 1", "tap --id row --label-contains Bluetooth"],
            context: context, session: backend.session, continueOnError: false, output: output, logger: OffsiderLogger()
        )

        #expect(backend.session.calls == [.perform(.tapAt(x: 195, y: 322))])
        let first = try #require(try JSONSerialization.jsonObject(with: Data(out.split(separator: "\n")[0].utf8)) as? [String: Any])
        #expect(first["met"] as? Bool == true)
        #expect(first["nearest"] as? [Any] != nil)
    }

    @Test("screenshot --mask-label-contains paints every element whose label holds the text, and names one that matches nothing")
    func maskLabelContains() async throws {
        let backend = try ScreenshotMaskTests.backend([
            FakeUI.node(.text, label: "Email: someone at example", frame: FakeUI.frame(20, 100, 200, 30)),
            FakeUI.node(.text, label: "Backup email: another", frame: FakeUI.frame(20, 200, 200, 30)),
            FakeUI.node(.text, label: "Phone", frame: FakeUI.frame(20, 300, 200, 30)),
        ])
        let result = try await ScreenshotMaskTests.capture(["--mask-label-contains", "mail:", "--mask-label-contains", "Fax"], on: backend)
        defer { try? FileManager.default.removeItem(atPath: result.path) }

        #expect(result.report.maskedBy == [.labelContains: 2])
        #expect(result.report.maskUnmatched == ["--mask-label-contains Fax"])
        #expect(result.report.jsonLine().contains(#""maskedBy":{"labelContains":2}"#))
        #expect(ScreenshotMaskTests.point(result.image, 100, 115) == ScreenshotMaskTests.black)
        #expect(ScreenshotMaskTests.point(result.image, 100, 215) == ScreenshotMaskTests.black)
        #expect(ScreenshotMaskTests.point(result.image, 100, 315) == ScreenshotMaskTests.white)
    }

    @Test("records show --mask-label-contains values as a character count, and keep type's --into-label-contains as an option")
    func redaction() {
        #expect(SelectorRedaction.redacted(["screenshot", "--mask-label-contains", "Email: me"]) == ["screenshot", "--mask-label-contains", "<9 characters>"])
        #expect(BatchStepRedaction.redactedLine("", tokens: ["type", "secret", "--into-label-contains", "Email"]) == "type <6 characters> --into-label-contains Email")
    }
}
