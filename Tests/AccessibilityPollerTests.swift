import Foundation
import OffsiderCore
import Testing
@testable import Offsider

@Suite("Accessibility poller")
@MainActor
struct AccessibilityPollerTests {
    private struct Flicker: TransientFailure, Equatable {
        var isTransient = true
    }

    private static let tree = UITree(platform: .android, device: "emulator-5556", roots: [
        UINode(role: .button, id: "go", frame: UIFrame(x: 10, y: 10, width: 100, height: 40), native: .android(AndroidNativeAttributes())),
    ])

    /// Throws the scripted errors in order, then returns the tree.
    private final class Reads {
        var failures: [any Error]
        var count = 0
        init(_ failures: [any Error]) { self.failures = failures }

        func next() throws -> UITree {
            count += 1
            if !failures.isEmpty { throw failures.removeFirst() }
            return AccessibilityPollerTests.tree
        }
    }

    private func resolve(_ reads: Reads, wait: TimeInterval = 0, grace: TimeInterval = 0) async throws -> TapResolution {
        try await AccessibilityPoller.pollForResolution(
            query: .id("go"),
            waitTimeout: wait,
            pollInterval: 0.01,
            transientGrace: grace,
            elementType: nil,
            logger: OffsiderLogger()
        ) { try reads.next() }.value
    }

    @Test("a transient read failure is retried within the verify grace")
    func transientFailureRetriedUnderGrace() async throws {
        let reads = Reads([Flicker()])
        let resolution = try await resolve(reads, grace: 2)
        #expect(resolution.point.x == 60)
        #expect(reads.count == 2)
    }

    @Test("a transient read failure is retried under --wait-timeout")
    func transientFailureRetriedUnderWait() async throws {
        let reads = Reads([Flicker(), Flicker()])
        _ = try await resolve(reads, wait: 2)
        #expect(reads.count == 3)
    }

    @Test("without --wait-timeout or --verify a transient failure is the error")
    func transientFailureWithoutWindowThrows() async {
        let reads = Reads([Flicker()])
        await #expect(throws: Flicker.self) { try await resolve(reads) }
        #expect(reads.count == 1)
    }

    @Test("a transient failure that persists past the grace is the error")
    func persistentTransientFailureThrows() async {
        let reads = Reads(Array(repeating: Flicker(), count: 1000))
        await #expect(throws: Flicker.self) { try await resolve(reads, grace: 0.1) }
        #expect(reads.count >= 2)
    }

    @Test("a failure that is not transient is never retried")
    func otherFailuresAreNotRetried() async {
        let reads = Reads([Flicker(isTransient: false)])
        await #expect(throws: Flicker.self) { try await resolve(reads, wait: 2, grace: 2) }
        #expect(reads.count == 1)
    }

    @Test("the verify grace does not extend the wait for a missing element")
    func graceDoesNotWaitForMissingElements() async {
        let empty = UITree(platform: .android, device: "emulator-5556", roots: [])
        var count = 0
        await #expect(throws: ElementResolutionError.self) {
            try await AccessibilityPoller.pollForResolution(
                query: .id("go"), waitTimeout: 0, pollInterval: 0.01, transientGrace: 2, elementType: nil, logger: OffsiderLogger()
            ) {
                count += 1
                return empty
            }
        }
        #expect(count == 1)
    }

    private static func sheet(buttonY: Double) -> UITree {
        FakeUI.tree(width: 393, height: 852, [
            FakeUI.node(.button, id: "apply", label: "Apply", frame: FakeUI.frame(20, buttonY, 350, 44)),
        ])
    }

    @Test("an off-screen element is retried under --wait-timeout until it slides on screen")
    func offScreenRetriedUnderWait() async throws {
        var trees = [Self.sheet(buttonY: 10700), Self.sheet(buttonY: 10700), Self.sheet(buttonY: 600)]
        var count = 0
        let polled = try await AccessibilityPoller.pollForResolution(
            query: .id("apply"), waitTimeout: 2, pollInterval: 0.01, elementType: nil, logger: OffsiderLogger()
        ) {
            count += 1
            return trees.count > 1 ? trees.removeFirst() : trees[0]
        }
        #expect(polled.value.point.y == 622)
        #expect(polled.tree == Self.sheet(buttonY: 600))
        #expect(count == 3)
    }

    @Test("an off-screen element is not retried without --wait-timeout")
    func offScreenNotRetriedWithoutWait() async {
        var count = 0
        let error = await #expect(throws: ElementResolutionError.self) {
            try await AccessibilityPoller.pollForResolution(
                query: .id("apply"), waitTimeout: 0, pollInterval: 0.01, elementType: nil, logger: OffsiderLogger()
            ) {
                count += 1
                return Self.sheet(buttonY: 10700)
            }
        }
        #expect(error?.isOffScreen == true)
        #expect(count == 1)
    }

    @Test("point descriptions round to 0.01 and drop a zero fraction")
    func pointDescriptionsAreRounded() {
        #expect(VerifyOutput.pointDescription(x: 217.14999999999998, y: 272.195) == "(217.15, 272.2)")
        #expect(VerifyOutput.pointDescription(x: 200, y: 400) == "(200, 400)")
        #expect(VerifyOutput.pointDescription(x: 205.72000000000003, y: 477.71) == "(205.72, 477.71)")
    }
}
