import Foundation
import OffsiderCore
import Testing
@testable import Offsider

@Suite("Transition guard")
@MainActor
struct TransitionGuardTests {
    static let device = DeviceID(rawValue: "fake-device", platform: .ios)
    static let now = Date(timeIntervalSince1970: 1_800_000_000)

    static func apply(y: Double) -> UINode {
        FakeUI.node(.button, id: "apply", label: "Apply", frame: FakeUI.frame(20, y, 350, 44))
    }

    static func screen(applyY: Double) -> UITree {
        FakeUI.tree([FakeUI.node(.button, id: "open", label: "Open", frame: FakeUI.frame(20, 100, 350, 44)), apply(y: applyY)])
    }

    static func record(applyY: Double?, inputAge: TimeInterval?, now: Date = TransitionGuardTests.now) -> TreeCacheRecord {
        let tree = applyY.map(screen(applyY:))
        return TreeCacheRecord(
            platform: .ios, device: device.rawValue, command: "tap", writtenAt: now - 0.05,
            lastInputAt: inputAge.map { now - $0 }, treeRole: tree == nil ? nil : .preAction,
            appFrame: tree?.applicationFrame, roots: tree?.roots
        )
    }

    // MARK: Decisions

    @Test("input 500 ms or more ago, or none at all, acts at once")
    func noRecentInput() {
        #expect(TransitionGuard.decide(target: Self.apply(y: 600), record: Self.record(applyY: 700, inputAge: 0.5), now: Self.now) == .actNow(.noRecentInput))
        #expect(TransitionGuard.decide(target: Self.apply(y: 600), record: Self.record(applyY: nil, inputAge: nil), now: Self.now) == .actNow(.noRecentInput))
    }

    @Test("a target within 1 pt of its cached frame acts at once")
    func sameFrame() {
        #expect(TransitionGuard.decide(target: Self.apply(y: 600.9), record: Self.record(applyY: 600, inputAge: 0.1), now: Self.now) == .actNow(.sameFrame))
        #expect(TransitionGuard.decide(target: Self.apply(y: 601.5), record: Self.record(applyY: 600, inputAge: 0.1), now: Self.now) == .recheck(after: .milliseconds(400)))
    }

    @Test("a moved target waits out the rest of 500 ms; a clock that stepped back waits all of it")
    func movedWaits() {
        #expect(TransitionGuard.decide(target: Self.apply(y: 650), record: Self.record(applyY: 10700, inputAge: 0.12), now: Self.now) == .recheck(after: .milliseconds(380)))
        #expect(TransitionGuard.decide(target: Self.apply(y: 650), record: Self.record(applyY: nil, inputAge: -3), now: Self.now) == .recheck(after: .milliseconds(500)))
    }

    @Test("no record waits 150 ms")
    func noRecord() {
        #expect(TransitionGuard.decide(target: Self.apply(y: 600), record: nil, now: Self.now) == .recheck(after: .milliseconds(150)))
    }

    // MARK: Tap

    private static func tap(_ arguments: [String], on backend: FakeDeviceBackend, fixture: TreeCacheFixture) async throws {
        try await fixture.run {
            try await Tap.parse(arguments + ["--device", device.rawValue])
                .execute(on: DeviceRouter.Route(backend: backend, device: device), progress: nil, logger: OffsiderLogger())
        }
    }

    @Test("a selector tap with a settled cache reads the tree once")
    func settledReadsOnce() async throws {
        let fixture = try TreeCacheFixture()
        try fixture.write(fixture.settledRecord(Self.screen(applyY: 600)))
        let backend = FakeDeviceBackend(trees: [Self.screen(applyY: 600)])

        try await Self.tap(["--id", "apply"], on: backend, fixture: fixture)

        #expect(backend.treeReads == 1)
        #expect(fixture.sleeps.isEmpty)
        #expect(backend.session.calls == [.perform(.tapAt(x: 195, y: 622))])
    }

    @Test("a selector tap right after input on a moving target reads twice and taps the settled point")
    func movingTargetRechecks() async throws {
        let fixture = try TreeCacheFixture()
        try fixture.write(Self.record(applyY: 10700, inputAge: 0.1, now: fixture.now))
        let backend = FakeDeviceBackend(trees: [Self.screen(applyY: 650), Self.screen(applyY: 600)])

        try await Self.tap(["--id", "apply"], on: backend, fixture: fixture)

        #expect(backend.treeReads == 2)
        #expect(fixture.sleeps == [.milliseconds(400)])
        #expect(backend.session.calls == [.perform(.tapAt(x: 195, y: 622))])
    }

    @Test("a selector tap with no record waits 150 ms and reads once more")
    func noRecordRechecks() async throws {
        let fixture = try TreeCacheFixture()
        let backend = FakeDeviceBackend(trees: [Self.screen(applyY: 650), Self.screen(applyY: 600)])

        try await Self.tap(["--id", "apply"], on: backend, fixture: fixture)

        #expect(backend.treeReads == 2)
        #expect(fixture.sleeps == [.milliseconds(150)])
        #expect(backend.session.calls == [.perform(.tapAt(x: 195, y: 622))])
    }

    @Test("--no-settle reads once whatever the cache says")
    func noSettle() async throws {
        let fixture = try TreeCacheFixture()
        try fixture.write(Self.record(applyY: 10700, inputAge: 0.1, now: fixture.now))
        let backend = FakeDeviceBackend(trees: [Self.screen(applyY: 650), Self.screen(applyY: 600)])

        try await Self.tap(["--id", "apply", "--no-settle"], on: backend, fixture: fixture)

        #expect(backend.treeReads == 1)
        #expect(fixture.sleeps.isEmpty)
        #expect(backend.session.calls == [.perform(.tapAt(x: 195, y: 672))])
    }

    @Test("a target gone from the re-read is tapped where it was first found")
    func goneTappedWhereFound() async throws {
        let fixture = try TreeCacheFixture()
        let backend = FakeDeviceBackend(trees: [Self.screen(applyY: 650), FakeUI.tree([])])

        try await Self.tap(["--id", "apply"], on: backend, fixture: fixture)

        #expect(backend.treeReads == 2)
        #expect(backend.session.calls == [.perform(.tapAt(x: 195, y: 672))])
    }

    @Test("re-resolution picks the copy nearest where the target was first found")
    func nearestCopy() async throws {
        let fixture = try TreeCacheFixture()
        let doubled = FakeUI.tree([Self.apply(y: 300), Self.apply(y: 640)])
        let backend = FakeDeviceBackend(trees: [Self.screen(applyY: 650), doubled])

        try await Self.tap(["--id", "apply"], on: backend, fixture: fixture)

        #expect(backend.session.calls == [.perform(.tapAt(x: 195, y: 662))])
    }

    // MARK: Slider and batch

    @Test("a slider found mid-transition is resolved at its settled frame")
    func sliderSettles() async throws {
        let fixture = try TreeCacheFixture()
        func slider(_ y: Double) -> UITree {
            FakeUI.tree([FakeUI.node(.slider, id: "volume", value: "50%", frame: FakeUI.frame(20, y, 360, 20))])
        }
        let backend = FakeDeviceBackend(trees: [slider(700), slider(600)])
        let record = TreeCacheRecord(platform: .ios, device: Self.device.rawValue, command: "tap", writtenAt: fixture.now, lastInputAt: fixture.now - 0.2)

        let polled = try await fixture.run {
            try await AccessibilityPoller.resolveElementWithPolling(
                query: .id("volume"), on: backend, device: Self.device, waitTimeout: 0, pollInterval: 0.25,
                settle: .guarded(record: record), logger: OffsiderLogger()
            )
        }

        #expect(polled.value.element.frame?.y == 600)
        #expect(backend.treeReads == 2)
        #expect(fixture.sleeps == [.milliseconds(300)])
    }

    @Test("a tap step after an input step uses the in-memory pre-action tree, not the disk")
    func batchUsesMemory() async throws {
        let fixture = try TreeCacheFixture()
        let settled = TreeCacheRecord(platform: .ios, device: Self.device.rawValue, command: "describe-ui", writtenAt: fixture.now - 5, lastInputAt: fixture.now - 5)
        let backend = FakeDeviceBackend(trees: [Self.screen(applyY: 10700), Self.screen(applyY: 650), Self.screen(applyY: 600)])

        try await fixture.run {
            let context = BatchContext(
                backend: backend, device: Self.device, axCachePolicy: .perBatch, typeSubmissionMode: .chunked, typeChunkSize: 200,
                cachedRecord: settled
            )
            try await Batch.runSteps(["tap --id open", "tap --id apply"], context: context, session: backend.session, continueOnError: false, logger: OffsiderLogger())
        }

        #expect(backend.treeReads == 3)
        #expect(fixture.sleeps == [.milliseconds(500)])
        #expect(backend.session.calls == [.perform(.tapAt(x: 195, y: 122)), .perform(.tapAt(x: 195, y: 622))])
    }
}
