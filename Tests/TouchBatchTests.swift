import Foundation
import OffsiderCore
import Testing
@testable import Offsider

@Suite("Batch touch steps")
@MainActor
struct TouchBatchTests {
    static func primitives(on device: DeviceID) async throws -> [BatchPrimitive] {
        let context = BatchContext(
            backend: StubBackend(session: RecordingInputSession()), device: device,
            axCachePolicy: .perBatch, typeSubmissionMode: .composite, typeChunkSize: 2
        )
        return try await Touch.parse(["-x", "5", "-y", "6", "--down", "--up", "--delay", "2", "--device", device.rawValue])
            .toBatchPrimitives(context: context, logger: OffsiderLogger())
    }

    @Test("on a physical iOS device a long press is one event, so the device session times its hold")
    func physicalDevice() async throws {
        let primitives = try await Self.primitives(on: DeviceID(rawValue: "00008130-0000000000000ABC", platform: .ios))
        guard primitives.count == 1, case .hidBarrier(let event) = primitives[0] else {
            Issue.record("expected one barrier, got \(primitives)")
            return
        }
        #expect(event == .composite([.touch(direction: .down, x: 5, y: 6), .delay(2), .touch(direction: .up, x: 5, y: 6)]))
    }

    @Test("on a simulator the hold stays a host sleep between two barriers")
    func simulator() async throws {
        let primitives = try await Self.primitives(on: DeviceID(rawValue: UUID().uuidString, platform: .ios))
        #expect(primitives.count == 3)
        guard case .hostSleep(let seconds) = primitives[1] else {
            Issue.record("expected a host sleep, got \(primitives)")
            return
        }
        #expect(seconds == 2)
    }
}
