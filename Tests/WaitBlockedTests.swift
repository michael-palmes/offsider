import ArgumentParser
import Foundation
import OffsiderCore
import Testing
@testable import Offsider

@Suite("Waits while the LogBox inspector hides the app")
@MainActor
struct WaitBlockedTests {
    /// Probe results served in order, holding the last, on a clock that moves only when the loop sleeps.
    private final class Script {
        var now: TimeInterval = 0
        var reads = 0
        var results: [ElementProbe] = []

        var probe: (UITree) -> ElementProbe {
            { [self] _ in
                defer { reads += 1 }
                return results[min(reads, results.count - 1)]
            }
        }

        var sources: WaitSources {
            WaitSources(
                tree: { FakeUI.tree() },
                fingerprint: { throw CLIError(errorDescription: "no screen") },
                sleep: { [self] duration in now += Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18 },
                now: { [self] in now }
            )
        }
    }

    private static let block = LogBoxBlock(subject: "--id 'fallback'", minimize: true)
    private static let save = FakeUI.node(.button, id: "save", label: "Save", frame: FakeUI.frame(20, 600, 350, 44))

    @Test("a selector the inspector keeps hidden stops after 1.5 s over two reads or more, not at the timeout")
    func blockedStopsAfterGrace() async {
        let script = Script()
        script.results = [.blocked(Self.block)]

        let error = await #expect(throws: WaitBlockedError.self) {
            try await WaitLoop.run(.element(probe: script.probe, gone: false), timeout: 60, interval: 0.25, sources: script.sources)
        }

        #expect(error == WaitBlockedError(block: Self.block, gone: false))
        #expect(script.now == 1.5)
        #expect(script.reads == 7)
    }

    @Test("a block that lifts restarts the grace, and a match after it is met")
    func blockThenClearThenMet() async throws {
        let script = Script()
        script.results = [.blocked(Self.block), .blocked(Self.block), .blocked(Self.block), .absent(reason: "not found"), .blocked(Self.block), .blocked(Self.block), .present(Self.save)]

        let outcome = try await WaitLoop.run(.element(probe: script.probe, gone: false), timeout: 60, interval: 0.25, sources: script.sources)

        #expect(outcome.met && outcome.match == Self.save)
        #expect(outcome.elapsed == 1.5)
    }

    @Test("with no time to hold the block, as for assert or a short --timeout, a blocked last read stops the check", arguments: [0.0, 1.0])
    func blockedLastReadStops(timeout: Double) async {
        let script = Script()
        script.results = [.blocked(Self.block)]

        await #expect(throws: WaitBlockedError(block: Self.block, gone: false)) {
            try await WaitLoop.run(.element(probe: script.probe, gone: false), timeout: timeout, interval: 0.25, sources: script.sources)
        }
        #expect(script.now == timeout)
    }

    @Test("--gone never passes while the inspector hides the app, and says it cannot tell")
    func goneStops() async {
        let script = Script()
        script.results = [.present(Self.save), .blocked(Self.block)]

        let error = await #expect(throws: WaitBlockedError.self) {
            try await WaitLoop.run(.element(probe: script.probe, gone: true, stableFor: 0.5), timeout: 10, interval: 0.25, sources: script.sources)
        }

        #expect(error?.gone == true)
        #expect(error?.message == "The React Native LogBox inspector is open in its own window, which hides the app on Android, so Offsider cannot tell whether --id 'fallback' is gone. Close it, then try again.")
    }

    @Test("wait --any stops only when every selector is blocked; one plain miss among them times out as usual")
    func anyNeedsEveryBlock() async throws {
        let other = LogBoxBlock(subject: "--label 'Retry'", minimize: true)
        func selector(_ text: String, _ position: Int) -> WaitMatch { WaitMatch(by: "label", text: text, position: position, of: 2) }
        let blocked = WaitCondition.anyElement([
            (selector("fallback", 1), { _ in .blocked(Self.block) }),
            (selector("Retry", 2), { _ in .blocked(other) }),
        ])

        let error = await #expect(throws: WaitBlockedError.self) {
            try await WaitLoop.run(blocked, timeout: 5, interval: 0.25, sources: Script().sources)
        }
        #expect(error?.message.contains("so --id 'fallback' or --label 'Retry' cannot appear.") == true)

        let mixed = WaitCondition.anyElement([
            (selector("fallback", 1), { _ in .blocked(Self.block) }),
            (selector("Retry", 2), { _ in .absent(reason: "not found") }),
        ])
        let outcome = try await WaitLoop.run(mixed, timeout: 0.5, interval: 0.25, sources: Script().sources)
        #expect(!outcome.met)
        #expect(outcome.reason == "--label 'fallback' not found; LogBox inspector open; --label 'Retry' not found")
    }

    @Test("the failure is logbox_inspector_open, exit 1 with nothing dispatched, and points at Minimize, else at rn logbox dismiss")
    func errorContract() {
        let error = WaitBlockedError(block: Self.block, gone: false)
        let payload = ErrorPayload(error)

        #expect(payload.reason == .logBoxInspectorOpen && payload.exitCode == .failure)
        #expect(payload.dispatched == nil)
        #expect(payload.message == "The React Native LogBox inspector is open in its own window, which hides the app on Android, so --id 'fallback' cannot appear. Close it, then try again.")
        #expect(payload.hint == "offsider tap --label Minimize --device <DEVICE_ID>")
        #expect(WaitBlockedError(block: LogBoxBlock(subject: "--id 'fallback'", minimize: false), gone: false).hint == "offsider rn logbox dismiss --device <DEVICE_ID>")
    }

    // MARK: Commands

    static let android = DeviceID(rawValue: "emulator-5554", platform: .android)
    static let ios = DeviceID(rawValue: "fake-device", platform: .ios)
    static let fallback = FakeUI.node(.button, id: "fallback", label: "Render Error Caught", frame: FakeUI.frame(20, 120, 350, 44))

    private static func wait(_ arguments: [String], on backend: FakeDeviceBackend, device: DeviceID = android, clock: ScriptedClock? = nil) async throws -> WaitOutcome {
        try await Wait.parse(arguments + ["--device", device.rawValue])
            .evaluate(on: DeviceRouter.Route(backend: backend, device: device), logger: OffsiderLogger(), clock: (clock ?? ScriptedClock()).poll)
    }

    private static func assert(_ arguments: [String], on backend: FakeDeviceBackend, device: DeviceID = android) async throws -> WaitOutcome {
        try await Assert.parse(arguments + ["--device", device.rawValue])
            .evaluate(on: DeviceRouter.Route(backend: backend, device: device), logger: OffsiderLogger())
    }

    @Test("on Android a wait for an app element under the inspector fails in under 2 s, naming the selector, rather than running its whole timeout")
    func androidWaitFailsFast() async {
        let backend = FakeDeviceBackend(platform: .android, trees: [LogBoxTrees.androidInspector()])
        let clock = ScriptedClock()

        let error = await #expect(throws: WaitBlockedError.self) {
            _ = try await Self.wait(["--id", "fallback", "--timeout", "60"], on: backend, clock: clock)
        }

        #expect(clock.now < 2)
        #expect(error?.reason == .logBoxInspectorOpen)
        #expect(error?.message.contains("so --id 'fallback' cannot appear.") == true)
        #expect(backend.session.calls.isEmpty)
    }

    @Test("the inspector's own buttons are met while it is open, and the app's element once Minimize closes it")
    func insideInspectorAndAfterMinimize() async throws {
        let inspector = FakeDeviceBackend(platform: .android, trees: [LogBoxTrees.androidInspector()])
        #expect(try await Self.wait(["--label", "Dismiss", "--timeout", "5"], on: inspector).met)

        let closing = FakeDeviceBackend(platform: .android, trees: [LogBoxTrees.androidInspector(), LogBoxTrees.androidInspector(), LogBoxTrees.androidApp([Self.fallback])])
        let outcome = try await Self.wait(["--id", "fallback", "--timeout", "60"], on: closing)
        #expect(outcome.met && outcome.match?.id == "fallback")
    }

    @Test("on iOS the inspector is drawn over the app, which stays in the tree, so its element is met")
    func iosInspectorKeepsApp() async throws {
        let backend = FakeDeviceBackend(trees: [FakeUI.tree([Self.fallback] + LogBoxTrees.inspector())])

        let outcome = try await Self.wait(["--id", "fallback", "--timeout", "5"], on: backend, device: Self.ios)

        #expect(outcome.met)
    }

    @Test("on iOS a plain timeout notes the open inspector in its last reason")
    func iosTimeoutNotesInspector() async throws {
        let backend = FakeDeviceBackend(trees: [FakeUI.tree(LogBoxTrees.inspector())])
        let wait = try Wait.parse(["--id", "fallback", "--timeout", "0", "--device", Self.ios.rawValue])

        let outcome = try await wait.evaluate(on: DeviceRouter.Route(backend: backend, device: Self.ios), logger: OffsiderLogger(), clock: ScriptedClock().poll)

        #expect(wait.failureLine(outcome) == "✗ Timed out after 0 s waiting for --id 'fallback' (last: not found; LogBox inspector open).")
    }

    @Test("assert stops at once on Android under the inspector, passes for its buttons, and on iOS reads as not found with the inspector open")
    func assertUnderInspector() async throws {
        let android = FakeDeviceBackend(platform: .android, trees: [LogBoxTrees.androidInspector(minimize: false)])
        let error = await #expect(throws: WaitBlockedError.self) {
            _ = try await Self.assert(["--id", "fallback"], on: android)
        }
        #expect(error?.hint == "offsider rn logbox dismiss --device <DEVICE_ID>")
        #expect(android.treeReads == 1)

        #expect(try await Self.assert(["--label", "Dismiss"], on: FakeDeviceBackend(platform: .android, trees: [LogBoxTrees.androidInspector()])).met)

        let ios = try Assert.parse(["--id", "fallback", "--device", Self.ios.rawValue])
        let outcome = try await ios.evaluate(on: DeviceRouter.Route(backend: FakeDeviceBackend(trees: [FakeUI.tree(LogBoxTrees.inspector())]), device: Self.ios), logger: OffsiderLogger())
        #expect(ios.failureLine(outcome) == "✗ Assertion failed: --id 'fallback' was not found; LogBox inspector open.")
    }

    @Test("a batch wait step under the inspector fails with the same reason and hint, and dispatches nothing")
    func batchWaitStep() async throws {
        let backend = FakeDeviceBackend(platform: .android, trees: [LogBoxTrees.androidInspector()])
        let context = BatchContext(backend: backend, device: Self.android, axCachePolicy: .perBatch, typeSubmissionMode: .chunked, typeChunkSize: 200)
        var out = ""
        let output = BatchOutput(json: true, write: { out += $0 }, writeError: { _ in })

        let error = await #expect(throws: ReportedFailure.self) {
            _ = try await Batch.runSteps(["wait --id fallback --timeout 0"], context: context, session: backend.session, continueOnError: false, output: output, logger: OffsiderLogger())
        }

        #expect(error?.exitCode == .failure)
        let record = try #require(try JSONSerialization.jsonObject(with: Data(out.split(separator: "\n")[0].utf8)) as? [String: Any])
        let payload = try #require(record["error"] as? [String: Any])
        #expect(payload["reason"] as? String == "logbox_inspector_open")
        #expect((payload["hint"] as? String)?.hasPrefix("offsider tap --label Minimize --device ") == true)
        #expect(backend.session.calls.isEmpty)
    }
}
