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

@Suite("Two-finger touch")
@MainActor
struct TwoFingerTouchTests {
    static let device = DeviceID(rawValue: UUID().uuidString, platform: .ios)

    @Test("usage errors name the fix", arguments: [
        (["--fingers", "2"], "--fingers 2 needs --hold"),
        (["--fingers", "2", "--hold", "500", "--down"], "drop --down, --up and --delay"),
        (["--fingers", "2", "--hold", "500", "--delay", "1"], "drop --down, --up and --delay"),
        (["--fingers", "2", "--hold", "99"], "--hold must be from 100 to 10000"),
        (["--fingers", "2", "--hold", "10001"], "--hold must be from 100 to 10000"),
        (["--fingers", "2", "--hold", "500", "--spread", "19"], "--spread must be from 20 to 300"),
        (["--fingers", "3", "--hold", "500"], "--fingers must be 1 or 2"),
        (["--hold", "500", "--down", "--up"], "hold with --down --up --delay"),
        (["--spread", "40", "--down"], "--spread needs --fingers 2"),
    ])
    func usage(arguments: [String], message: String) {
        let error = #expect(throws: (any Error).self) {
            _ = try Touch.parse(["-x", "200", "-y", "400"] + arguments + ["--device", Self.device.rawValue])
        }
        #expect(error.map { Touch.message(for: $0).contains(message) } == true, "\(error.map { Touch.message(for: $0) } ?? "no error")")
    }

    @Test("two fingers with a hold need neither --down nor --up")
    func parses() throws {
        let touch = try Touch.parse(["-x", "200", "-y", "400", "--fingers", "2", "--hold", "1000", "--device", Self.device.rawValue])
        #expect(touch.fingers == 2 && touch.hold == 1000)
    }

    @Test("the fingers sit half the spread either side of the centre, and one off the screen is named")
    func fingerPoints() throws {
        let points = try Touch.fingerPoints(x: 200, y: 400, spread: 60, screen: UISize(width: 402, height: 874))
        #expect(points.map(\.x) == [170, 230] && points.map(\.y) == [400, 400])

        let error = #expect(throws: CLIError.self) {
            try Touch.fingerPoints(x: 390, y: 400, spread: 60, screen: UISize(width: 402, height: 874))
        }
        #expect(error?.reason == .usage)
        #expect(error?.errorDescription?.contains("Finger 2 at (420, 400) is off the screen") == true)
        #expect(throws: CLIError.self) { try Touch.fingerPoints(x: 10, y: 400, spread: 60, screen: nil) }
    }

    @Test("a batch step is one barrier: both fingers down, the hold, both up")
    func batch() async throws {
        let context = BatchContext(
            backend: StubBackend(session: RecordingInputSession()), device: Self.device,
            axCachePolicy: .perBatch, typeSubmissionMode: .composite, typeChunkSize: 2
        )
        let primitives = try await Touch.parse(["-x", "200", "-y", "400", "--fingers", "2", "--hold", "900", "--spread", "100", "--device", Self.device.rawValue])
            .toBatchPrimitives(context: context, logger: OffsiderLogger())
        guard primitives.count == 1, case .hidBarrier(let event) = primitives[0] else {
            Issue.record("expected one barrier, got \(primitives)")
            return
        }
        #expect(event == .composite([
            .twoFingerTouch(direction: .down, x1: 150, y1: 400, x2: 250, y2: 400),
            .delay(0.9),
            .twoFingerTouch(direction: .up, x1: 150, y1: 400, x2: 250, y2: 400),
        ]))
    }
}
