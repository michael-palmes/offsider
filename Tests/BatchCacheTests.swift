import Foundation
import OffsiderCore
import Testing
@testable import Offsider

@Suite("Batch tree cache")
@MainActor
struct BatchCacheTests {
    private static let device = DeviceID(rawValue: "fake-device", platform: .ios)

    private static func button(_ label: String, y: Double) -> UINode {
        FakeUI.node(.button, label: label, frame: FakeUI.frame(20, y, 350, 44))
    }

    private static func run(_ steps: [String], on backend: FakeDeviceBackend, cache: AXCachePolicy = .perBatch) async throws {
        let context = BatchContext(
            backend: backend,
            device: device,
            axCachePolicy: cache,
            typeSubmissionMode: .chunked,
            typeChunkSize: 200,
            noSettle: true
        )
        try await Batch.runSteps(steps, context: context, session: backend.session, continueOnError: false, logger: OffsiderLogger())
    }

    @Test("the default cache reads a fresh tree after a step that sends input")
    func perBatchRefreshesAfterInput() async throws {
        let backend = FakeDeviceBackend(
            trees: [FakeUI.tree([Self.button("A", y: 100)]), FakeUI.tree([Self.button("B", y: 300)])],
            advanceTreeOnInput: true
        )

        try await Self.run(["tap --label A", "tap --label B"], on: backend)

        #expect(backend.session.calls == [.perform(.tapAt(x: 195, y: 122)), .perform(.tapAt(x: 195, y: 322))])
    }

    @Test("perStep reads the tree once per selector step")
    func perStepReadsOncePerStep() async throws {
        let backend = FakeDeviceBackend(trees: [FakeUI.tree([Self.button("A", y: 100)])], advanceTreeOnInput: true)

        try await Self.run(["tap --label A", "key 40", "tap --label A"], on: backend, cache: .perStep)

        #expect(backend.treeReads == 2)
        #expect(backend.coordinateCalls.map(\.hadTree) == [true, true])
    }

    @Test("an off-screen selector step fails unless the step allows it")
    func offScreenStep() async throws {
        let parked = FakeUI.tree(width: 393, height: 852, [Self.button("Apply", y: 10700)])

        let blocked = FakeDeviceBackend(trees: [parked])
        let error = await #expect(throws: ReportedFailure.self) {
            try await Self.run(["tap --label Apply"], on: blocked)
        }
        #expect(error?.exitCode == .selectorNotFound)
        #expect(error?.userFacingDescription.hasPrefix("Step 1 failed: [tap]\nMatched --label 'Apply' is off screen: its frame (20, 10700) 350x44") == true)
        #expect(blocked.session.calls.isEmpty)

        let allowed = FakeDeviceBackend(trees: [parked])
        try await Self.run(["tap --label Apply --allow-offscreen"], on: allowed)
        #expect(allowed.session.calls == [.perform(.tapAt(x: 195, y: 10722))])
    }
}
