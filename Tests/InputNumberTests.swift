import Foundation
import OffsiderCore
import Testing
@testable import Offsider

@Suite("Unusable input numbers")
@MainActor
struct InputNumberTests {
    static let device = DeviceID(rawValue: "fake-device", platform: .ios)

    @Test("a coordinate or time no device could act on is named, even nested in a gesture", arguments: [
        InputEvent.tapAt(x: .nan, y: 10),
        .tapAt(x: 1e19, y: 10),
        .twoFingerTouch(direction: .down, x1: 10, y1: 10, x2: 10, y2: -.infinity),
        .swipe(0, yStart: 0, xEnd: .infinity, yEnd: 0, delta: 10, duration: 0.3),
        .swipe(0, yStart: 0, xEnd: 100, yEnd: 0, delta: 10, duration: -1),
        .composite([.touch(direction: .down, x: 10, y: 10), .delay(1e9), .touch(direction: .up, x: 10, y: 10)]),
    ])
    func unusable(event: InputEvent) {
        #expect(event.unusableNumber != nil)
    }

    @Test("ordinary taps, gestures and keys, including a coordinate just off screen, are usable", arguments: [
        InputEvent.tapAt(x: -40, y: 120),
        .swipe(10, yStart: 600, xEnd: 10, yEnd: 100, delta: 10, duration: 0.3),
        .composite([.touch(direction: .down, x: 10, y: 10), .delay(1), .touch(direction: .up, x: 10, y: 10)]),
        .shortKeyPress(4),
    ])
    func usable(event: InputEvent) {
        #expect(event.unusableNumber == nil)
    }

    @Test("a tracked session refuses unusable numbers before the backend sees them, and records nothing as sent")
    func trackedSessionRefusesFirst() async throws {
        let recording = RecordingInputSession()
        let tracker = DispatchTracker()
        try await DispatchTracker.$current.withValue(tracker) {
            let session = TrackedInputSession.wrapping(recording)
            await #expect(throws: CLIError.self) { try await session.perform(.tapAt(x: 1e19, y: 10)) }
            await #expect(throws: CLIError.self) { try await session.performPhysicalTap(at: (x: 10, y: .nan), preDelay: nil, postDelay: nil) }
        }
        #expect(recording.calls.isEmpty)
        #expect(tracker.state == .no)
    }

    @Test("tap -x 1e19 exits as a usage error and sends nothing")
    func tapRefusesHugeCoordinate() async throws {
        let backend = FakeDeviceBackend(trees: [FakeUI.tree([])])
        await #expect(throws: CLIError.self) {
            try await DispatchTracker.$current.withValue(DispatchTracker()) {
                try await Tap.parse(["-x", "1e19", "-y", "10", "--device", Self.device.rawValue])
                    .execute(on: DeviceRouter.Route(backend: backend, device: Self.device), progress: nil, logger: OffsiderLogger())
            }
        }
        #expect(backend.session.calls.isEmpty)
    }
}
