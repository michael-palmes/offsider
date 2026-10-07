import CoreGraphics
import Foundation
import OffsiderCore
import Testing

@Suite("Wait loop")
@MainActor
struct WaitLoopTests {
    private struct Flicker: TransientFailure {
        var isTransient = true
    }

    private struct Broken: Error {}

    /// Scripted reads on a fake clock that only moves when the loop sleeps.
    private final class Script {
        var now: TimeInterval = 0
        var treeReads = 0
        var fingerprintReads = 0
        var trees: [Result<UITree, Error>] = []
        var fingerprints: [ImageFingerprint] = []

        var sources: WaitSources {
            WaitSources(
                tree: { [self] in
                    defer { treeReads += 1 }
                    return try trees[min(treeReads, trees.count - 1)].get()
                },
                fingerprint: { [self] in
                    defer { fingerprintReads += 1 }
                    return fingerprints[min(fingerprintReads, fingerprints.count - 1)]
                },
                sleep: { [self] duration in
                    now += Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
                },
                now: { [self] in now }
            )
        }
    }

    private static let save = FakeUI.node(.button, id: "save", label: "Save", frame: FakeUI.frame(20, 600, 350, 44))

    private static func screen(_ children: [UINode] = []) -> UITree {
        FakeUI.tree([FakeUI.node(.text, label: "Title", frame: FakeUI.frame(0, 0, 100, 20))] + children)
    }

    private static func probe(_ tree: UITree) -> ElementProbe {
        let match = tree.roots.flatMap { $0.flattened() }.first { $0.id == "save" }
        return match.map { .present($0) } ?? .absent(reason: "not found")
    }

    private static func fingerprint(marked: [(x: Int, y: Int)] = []) -> ImageFingerprint {
        ImageFingerprint(image: TestImages.make(width: 16, height: 16, marked: marked), columns: 4, rows: 4)!
    }

    @Test("an element that appears on the third read is met, with the time it took")
    func elementAppears() async throws {
        let script = Script()
        script.trees = [.success(Self.screen()), .success(Self.screen()), .success(Self.screen([Self.save]))]

        let outcome = try await WaitLoop.run(.element(probe: Self.probe, gone: false), timeout: 5, interval: 0.25, sources: script.sources)

        #expect(outcome == WaitOutcome(met: true, elapsed: 0.5, reason: "on screen", match: Self.save))
        #expect(script.treeReads == 3)
    }

    @Test("with a dwell, a 250 ms absence then a return does not satisfy gone, and 500 ms gone does")
    func goneDwell() async throws {
        let present = Result<UITree, Error>.success(Self.screen([Self.save]))
        let absent = Result<UITree, Error>.success(Self.screen())
        let flicker = Script()
        flicker.trees = [present, absent, absent, present, present, present, present, present, present]
        let outcome = try await WaitLoop.run(.element(probe: Self.probe, gone: true, stableFor: 0.5), timeout: 2, interval: 0.125, sources: flicker.sources)
        #expect(!outcome.met)
        #expect(outcome.reason == "still on screen")

        let leaves = Script()
        leaves.trees = [present, absent, absent, absent, absent, absent]
        let gone = try await WaitLoop.run(.element(probe: Self.probe, gone: true, stableFor: 0.5), timeout: 2, interval: 0.125, sources: leaves.sources)
        #expect(gone.met)
        #expect(gone.reason == "gone for 0.5 s")
        #expect(gone.elapsed == 0.625)
    }

    @Test("a dwell needs two reads, and a transient failure restarts it")
    func dwellReadsAndFailures() async throws {
        let script = Script()
        script.trees = [.success(Self.screen([Self.save])), .failure(Flicker()), .success(Self.screen([Self.save])), .success(Self.screen([Self.save]))]
        let outcome = try await WaitLoop.run(.element(probe: Self.probe, gone: false, stableFor: 0.5), timeout: 2, interval: 0.25, sources: script.sources)
        #expect(outcome.met)
        #expect(outcome.elapsed == 1)
        #expect(outcome.reason == "on screen for 0.5 s")
        #expect(outcome.match == Self.save)
    }

    @Test("gone is met once the element is absent")
    func elementGone() async throws {
        let script = Script()
        script.trees = [.success(Self.screen([Self.save])), .success(Self.screen())]

        let outcome = try await WaitLoop.run(.element(probe: Self.probe, gone: true), timeout: 5, interval: 0.25, sources: script.sources)

        #expect(outcome.met)
        #expect(outcome.reason == "not found")
        #expect(outcome.elapsed == 0.25)
    }

    @Test("a timeout is not met and carries the last reason")
    func timeoutKeepsLastReason() async throws {
        let script = Script()
        script.trees = [.success(Self.screen())]
        let parked: (UITree) -> ElementProbe = { _ in .absent(reason: "off screen at (20, 10700) 350x44") }

        let outcome = try await WaitLoop.run(.element(probe: parked, gone: false), timeout: 1, interval: 0.25, sources: script.sources)

        #expect(outcome == WaitOutcome(met: false, elapsed: 1, reason: "off screen at (20, 10700) 350x44"))
        #expect(script.treeReads == 5)
    }

    @Test("a zero timeout reads exactly once")
    func zeroTimeoutReadsOnce() async throws {
        let script = Script()
        script.trees = [.success(Self.screen()), .success(Self.screen([Self.save]))]

        let outcome = try await WaitLoop.run(.element(probe: Self.probe, gone: false), timeout: 0, interval: 0.25, sources: script.sources)

        #expect(!outcome.met)
        #expect(script.treeReads == 1)
        #expect(script.now == 0)
    }

    @Test("a transient read failure counts as not yet and is retried")
    func transientFailureRetried() async throws {
        let script = Script()
        script.trees = [.failure(Flicker()), .success(Self.screen([Self.save]))]

        let outcome = try await WaitLoop.run(.element(probe: Self.probe, gone: false), timeout: 5, interval: 0.25, sources: script.sources)

        #expect(outcome.met)
        #expect(script.treeReads == 2)
    }

    @Test("a wait that never read successfully throws the transient failure")
    func onlyTransientFailuresThrow() async {
        let script = Script()
        script.trees = [.failure(Flicker())]

        await #expect(throws: Flicker.self) {
            try await WaitLoop.run(.element(probe: Self.probe, gone: false), timeout: 0.5, interval: 0.25, sources: script.sources)
        }
    }

    @Test("other read failures stop the wait at once")
    func otherFailuresPropagate() async {
        let script = Script()
        script.trees = [.failure(Broken())]

        await #expect(throws: Broken.self) {
            try await WaitLoop.run(.element(probe: Self.probe, gone: false), timeout: 5, interval: 0.25, sources: script.sources)
        }
        #expect(script.treeReads == 1)
    }

    @Test("settled needs two reads and a full quiet window")
    func settledNeedsQuietWindow() async throws {
        let script = Script()
        script.trees = [.success(Self.screen([Self.save]))]

        let outcome = try await WaitLoop.run(.settled(by: .tree, quiet: 0.5), timeout: 5, interval: 0.25, sources: script.sources)

        #expect(outcome == WaitOutcome(met: true, elapsed: 0.5, reason: "settled"))
        #expect(script.treeReads == 3)
    }

    @Test("settled by tree on a tree that is never readable fails with a pointer to --settle-by screen")
    func unreadableTreeFails() async throws {
        let script = Script()
        script.trees = [.success(UITree(platform: .ios, device: "fake", roots: []))]

        let error = await #expect(throws: WaitUnreadableError.self) {
            try await WaitLoop.run(.settled(by: .tree, quiet: 0.5), timeout: 1, interval: 0.25, sources: script.sources)
        }
        #expect(error?.message.contains("--settle-by screen") == true)
        #expect(script.treeReads == 5)
    }

    @Test("settled by tree that was readable at least once still times out as unmet")
    func partlyReadableTreeTimesOut() async throws {
        let script = Script()
        script.trees = [.success(Self.screen([Self.save])), .success(UITree(platform: .ios, device: "fake", roots: []))]

        let outcome = try await WaitLoop.run(.settled(by: .tree, quiet: 0.5), timeout: 1, interval: 0.25, sources: script.sources)

        #expect(!outcome.met)
        #expect(outcome.reason == "accessibility tree not readable")
    }

    @Test("a tree change mid-way restarts the quiet window")
    func treeChangeResetsQuiet() async throws {
        var moved = Self.save
        moved.frame = FakeUI.frame(20, 300, 350, 44)
        let script = Script()
        script.trees = [.success(Self.screen([Self.save])), .success(Self.screen([moved]))]

        let outcome = try await WaitLoop.run(.settled(by: .tree, quiet: 0.5), timeout: 5, interval: 0.25, sources: script.sources)

        #expect(outcome.met)
        #expect(outcome.elapsed == 0.75)
    }

    private static func price(_ text: String, saveAt y: Double = 600) -> UITree {
        var save = Self.save
        save.frame = FakeUI.frame(20, y, 350, 44)
        return Self.screen([FakeUI.node(.text, id: "price", label: text, frame: FakeUI.frame(0, 100, 200, 30)), save])
    }

    @Test("with --ignore-values a ticking label lets the screen settle, resizing with its text or not, while a move still restarts the quiet window")
    func ignoreValuesSettlesOnTicker() async throws {
        let ticking = Script()
        ticking.trees = (0..<20).map { .success(Self.price("$\($0)")) }
        let settled = try await WaitLoop.run(.settled(by: .tree, quiet: 0.5, ignoreValues: true), timeout: 5, interval: 0.25, sources: ticking.sources)
        #expect(settled.met && settled.elapsed == 0.5)

        let resizing = Script()
        resizing.trees = (0..<20).map { tick in
            var tree = Self.price("$\(tick)")
            tree.roots[0].children[1].frame = FakeUI.frame(Double(300 - tick), 100, Double(80 + tick), 30)
            return .success(tree)
        }
        let resized = try await WaitLoop.run(.settled(by: .tree, quiet: 0.5, ignoreValues: true), timeout: 5, interval: 0.25, sources: resizing.sources)
        #expect(resized.met && resized.elapsed == 0.5, "a right-aligned ticker's frame follows its text")

        let moving = Script()
        moving.trees = [.success(Self.price("$1")), .success(Self.price("$2", saveAt: 300))]
        let moved = try await WaitLoop.run(.settled(by: .tree, quiet: 0.5, ignoreValues: true), timeout: 5, interval: 0.25, sources: moving.sources)
        #expect(moved.met && moved.elapsed == 0.75)
    }

    @Test("a ticking label without --ignore-values never settles, and the outcome says only text moved")
    func tickerTimesOutAsTextOnly() async throws {
        let ticking = Script()
        ticking.trees = (0..<20).map { .success(Self.price("$\($0)")) }
        let outcome = try await WaitLoop.run(.settled(by: .tree, quiet: 0.5), timeout: 1, interval: 0.25, sources: ticking.sources)
        #expect(!outcome.met && outcome.onlyTextMoved)

        let moving = Script()
        moving.trees = (0..<20).map { .success(Self.price("$\($0)", saveAt: 300 + Double($0))) }
        #expect(try await WaitLoop.run(.settled(by: .tree, quiet: 0.5), timeout: 1, interval: 0.25, sources: moving.sources).onlyTextMoved == false)
    }

    @Test("after an input, settled holds until a read differs from the screen before it, then waits a full quiet window")
    func gateWaitsForTheInputsEffect() async throws {
        let before = Self.screen([Self.save])
        let pushed = Self.screen([FakeUI.node(.header, id: "detail", label: "Detail", frame: FakeUI.frame(0, 60, 402, 44))])
        let script = Script()
        script.trees = [.success(before), .success(before), .success(before), .success(before), .success(pushed)]
        let gate = try #require(SettleGate(sinceInput: 0.1, before: before))
        let outcome = try await WaitLoop.run(.settled(by: .tree, quiet: 0.5, gate: gate), timeout: 5, interval: 0.25, sources: script.sources)
        #expect(outcome.met)
        #expect(outcome.elapsed == 1.5)
    }

    @Test("with no visible effect the gate opens 2 s after the input, or 1 s when no read from before it was kept", arguments: [(true, 2.0), (false, 1.0)])
    func gateOpensByTime(keptBefore: Bool, elapsed: TimeInterval) async throws {
        let script = Script()
        script.trees = [.success(Self.screen([Self.save]))]
        let gate = try #require(SettleGate(sinceInput: 0.2, before: keptBefore ? Self.screen([Self.save]) : nil))
        let outcome = try await WaitLoop.run(.settled(by: .tree, quiet: 0.5, gate: gate), timeout: 5, interval: 0.25, sources: script.sources)
        #expect(outcome.met)
        #expect(outcome.elapsed == elapsed)
    }

    @Test("the gate follows the last input's record: none after a verified input or an old one, the tree before an unverified one")
    func gateFromRecord() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func record(_ role: TreeCacheRecord.TreeRole?, inputAgo: TimeInterval?) -> TreeCacheRecord {
            TreeCacheRecord(
                platform: .ios, device: "fake", command: "tap", writtenAt: now, treeReadAt: now.addingTimeInterval(-1),
                lastInputAt: inputAgo.map { now.addingTimeInterval(-$0) }, treeRole: role, roots: role == nil ? nil : Self.screen([Self.save]).roots
            )
        }
        #expect(SettleGate.after(record(.postAction, inputAgo: 0.3), now: now) == nil)
        #expect(SettleGate.after(record(.preAction, inputAgo: 2.5), now: now) == nil)
        #expect(SettleGate.after(record(.read, inputAgo: nil), now: now) == nil)
        #expect(SettleGate.after(nil, now: now) == nil)
        #expect(SettleGate.after(record(.preAction, inputAgo: 0.3), now: now)?.before != nil)
        #expect(SettleGate.after(record(.preAction, inputAgo: 0.3), now: now)?.limit == SettleGate.hold)
        #expect(SettleGate.after(record(nil, inputAgo: 0.3), now: now)?.limit == SettleGate.floor)
        #expect(SettleGate.after(record(nil, inputAgo: 1.2), now: now) == nil)
    }

    @Test("a screen that keeps changing never settles and says so")
    func screenStillChanging() async throws {
        let script = Script()
        script.fingerprints = (0..<10).map { Self.fingerprint(marked: [(x: $0, y: 0)]) }

        let outcome = try await WaitLoop.run(.settled(by: .screen, quiet: 0.5), timeout: 1, interval: 0.25, sources: script.sources)

        #expect(outcome == WaitOutcome(met: false, elapsed: 1, reason: "screen still changing"))
        #expect(script.treeReads == 0)
    }

    @Test("region changed fires against the first capture")
    func regionChangedAgainstBaseline() async throws {
        let script = Script()
        let still = Self.fingerprint()
        script.fingerprints = [still, still, Self.fingerprint(marked: [(x: 1, y: 1)])]

        let outcome = try await WaitLoop.run(.region(mode: .changed, quiet: 0.5, threshold: 0), timeout: 5, interval: 0.25, sources: script.sources)

        #expect(outcome.met)
        #expect(outcome.elapsed == 0.5)
        #expect(outcome.reason.hasPrefix("Changed: 1 of 16 tiles"))
    }

    @Test("region changes within the threshold do not count")
    func regionChangeWithinThreshold() async throws {
        let script = Script()
        script.fingerprints = [Self.fingerprint(), Self.fingerprint(marked: [(x: 1, y: 1)])]

        let outcome = try await WaitLoop.run(.region(mode: .changed, quiet: 0.5, threshold: 0.1), timeout: 0.5, interval: 0.25, sources: script.sources)

        #expect(outcome == WaitOutcome(met: false, elapsed: 0.5, reason: "region unchanged"))
    }

    @Test("region stable waits for a quiet window after the last change")
    func regionStableWaitsForQuiet() async throws {
        let script = Script()
        let settledFrame = Self.fingerprint(marked: [(x: 9, y: 9)])
        script.fingerprints = [Self.fingerprint(), settledFrame]

        let outcome = try await WaitLoop.run(.region(mode: .stable, quiet: 0.5, threshold: 0), timeout: 5, interval: 0.25, sources: script.sources)

        #expect(outcome == WaitOutcome(met: true, elapsed: 0.75, reason: "region stable"))
    }

    @Test("a duration is always met after sleeping, with no reads")
    func durationAlwaysMet() async throws {
        let script = Script()

        let outcome = try await WaitLoop.run(.duration(2), timeout: 0, interval: 0.25, sources: script.sources)

        #expect(outcome.met)
        #expect(outcome.elapsed == 2)
        #expect(script.treeReads == 0 && script.fingerprintReads == 0)
    }

    @Test("seconds print whole numbers bare and others to one decimal")
    func secondsFormatting() {
        #expect(WaitLoop.seconds(10) == "10 s")
        #expect(WaitLoop.seconds(1.24) == "1.2 s")
        #expect(WaitLoop.seconds(0.96) == "1 s")
    }

    @Test("the report is one compact object with the unique match or null")
    func reportShape() {
        let missed = WaitReport(WaitOutcome(met: false, elapsed: 10.0004, reason: "not found")).jsonLine()
        #expect(missed == #"{"met":false,"elapsedMs":10000,"reason":"not found","match":null,"matched":null}"#)

        let found = WaitReport(WaitOutcome(met: true, elapsed: 1.2, reason: "on screen", match: Self.save)).jsonLine()
        #expect(found.hasPrefix(#"{"met":true,"elapsedMs":1200,"reason":"on screen","match":{"role":"button","id":"save","label":"Save","#))
        #expect(!found.contains("children"))
    }
}
