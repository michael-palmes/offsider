import Testing
import Foundation
import OffsiderCore
@testable import Offsider

@Suite("Drag Command Surface Tests")
struct DragCommandSurfaceTests {
    @Test("Drag help includes coordinate and timing options")
    func dragHelpIncludesCoordinateAndTimingOptions() async throws {
        let result = try await TestHelpers.runOffsiderCommand("drag --help")

        #expect(result.output.contains("--start-x"))
        #expect(result.output.contains("--start-y"))
        #expect(result.output.contains("--end-x"))
        #expect(result.output.contains("--end-y"))
        #expect(result.output.contains("--duration"))
        #expect(result.output.contains("--steps"))
    }

    @Test("Invalid drag coordinates fail validation")
    func invalidDragCoordinatesFailValidation() async throws {
        let result = try await TestHelpers.runOffsiderCommandAllowFailure(
            "drag --start-x 100 --start-y 100 --end-x 100 --end-y 100 --device invalid"
        )

        #expect(result.exitCode != 0)
        #expect(result.output.contains("Start and end points must be different."))
    }

    @Test("Too many drag steps fails validation")
    func tooManyDragStepsFailsValidation() async throws {
        let result = try await TestHelpers.runOffsiderCommandAllowFailure(
            "drag --start-x 100 --start-y 100 --end-x 100 --end-y 200 --steps 1001 --device invalid"
        )

        #expect(result.exitCode != 0)
        #expect(result.output.contains("Steps must be between 1 and 1000."))
    }

    @Test("Composite drag plan includes move points between touch down and touch up")
    @MainActor
    func compositeDragPlanIncludesMovePoints() throws {
        let movePoints = try HIDInteractor.compositeDragMovePoints(
            from: (x: 100, y: 200),
            to: (x: 300, y: 600),
            steps: 4
        )

        #expect(movePoints.count == 4)
        #expect(movePoints.first?.x == 150)
        #expect(movePoints.first?.y == 300)
        #expect(movePoints.last?.x == 300)
        #expect(movePoints.last?.y == 600)
        #expect(movePoints.contains { point in
            point.x > 100 && point.x < 300 && point.y > 200 && point.y < 600
        })
    }
}

@Suite("Drag hold")
struct DragHoldTests {
    static func holds(_ arguments: [String]) throws -> [TimeInterval] {
        let drag = try Drag.parse(["--start-x", "10", "--start-y", "10", "--end-x", "10", "--end-y", "110", "--steps", "2"] + arguments + ["--device", "emulator-5554"])
        guard case .composite(let events) = try drag.dragEvent(from: (x: 10, y: 10), to: (x: 10, y: 110)) else { return [] }
        return events.compactMap { if case .delay(let seconds) = $0 { return seconds } else { return nil } }
    }

    @Test("the finger holds 50 ms before it moves by default, and --hold-ms sets that hold")
    func holdBeforeMoving() throws {
        #expect(try Self.holds([]).first == 0.05)
        #expect(try Self.holds(["--hold-ms", "800"]).first == 0.8)
        #expect(try Self.holds(["--hold-ms", "0"]).first == 0)
    }

    @Test("--hold-ms outside 0 to 10000 is a usage error", arguments: ["-1", "10001"])
    func holdRange(value: String) {
        let error = #expect(throws: (any Error).self) { try Self.holds(["--hold-ms=\(value)"]) }
        #expect(error.map { Drag.message(for: $0).contains("--hold-ms must be from 0 to 10000") } == true)
    }

    @Test("the finger holds still 50 ms at the end before it lifts by default, and --hold-end sets that hold")
    func holdAtEnd() throws {
        #expect(try Self.holds([]).last == 0.05)
        #expect(try Self.holds(["--hold-end", "500"]).last == 0.5)
        #expect(try Self.holds(["--hold-end", "0"]).last == 0)
        #expect(try Self.holds(["--hold-end", "500"]).first == 0.05)
    }

    @Test("--hold-end outside 0 to 10000 is a usage error", arguments: ["-1", "10001"])
    func holdEndRange(value: String) {
        let error = #expect(throws: (any Error).self) { try Self.holds(["--hold-end=\(value)"]) }
        #expect(error.map { Drag.message(for: $0).contains("--hold-end must be from 0 to 10000") } == true)
    }

    @Test("--duration over 30 seconds is a usage error", arguments: ["31", "1e12"])
    func durationCap(value: String) {
        let error = #expect(throws: (any Error).self) { try Self.holds(["--duration", value]) }
        #expect(error.map { Drag.message(for: $0).contains("Duration must be at most 30 seconds") } == true)
    }
}

@Suite("Drag batch step")
@MainActor
struct DragBatchStepTests {
    static let device = DeviceID(rawValue: "STUB", platform: .ios)
    static let points = ["--start-x", "100", "--start-y", "300", "--end-x", "100", "--end-y", "600"]

    static func parse(_ arguments: [String]) async throws -> BatchStep {
        let context = BatchContext(backend: StubBackend(session: RecordingInputSession()), device: device, axCachePolicy: .perBatch, typeSubmissionMode: .composite, typeChunkSize: 1)
        return try await BatchStepParser.parseStep(["drag"] + arguments, deviceID: device.rawValue, context: context, logger: OffsiderLogger())
    }

    @Test("a batch drag step sends the command's own drag, with its holds and delays", arguments: [[], ["--hold-ms", "800", "--hold-end", "300", "--pre-delay", "0.2"]])
    func sendsTheCommandsDrag(extra: [String]) async throws {
        guard case .input(let primitives) = try await Self.parse(Self.points + extra), primitives.count == 1, case .hidMergeable(let event) = primitives[0] else {
            Issue.record("expected one mergeable input")
            return
        }
        let command = try Drag.parse(Self.points + extra + ["--device", Self.device.rawValue])
        #expect(event == InputEvent.delayed(try command.dragEvent(from: (x: 100, y: 300), to: (x: 100, y: 600)), pre: command.preDelay, post: command.postDelay))
    }

    @Test("a batch drag step is held to drag's limits", arguments: [
        (["--start-x", "1e19", "--start-y", "300", "--end-x", "100", "--end-y", "600"], "--start-x must be a number from -100000 to 100000"),
        (["--start-x", "100", "--start-y", "300", "--end-x", "100", "--end-y", "300"], "Start and end points must be different."),
        (points + ["--steps", "1001"], "Steps must be between 1 and 1000."),
        (points + ["--hold-ms", "10001"], "--hold-ms must be from 0 to 10000"),
    ])
    func limits(arguments: [String], message: String) async {
        let error = await #expect(throws: (any Error).self) { _ = try await Self.parse(arguments) }
        #expect(error.map { Drag.message(for: $0).contains(message) } == true, "\(error.map { Drag.message(for: $0) } ?? "")")
        #expect(error.map { Drag.exitCode(for: $0) } == .validationFailure)
    }
}

@Suite("Drag Command Tests", .serialized, .enabled(if: isE2EEnabled))
struct DragTests {
    @Test("Low-level drag records requested start and end points")
    func lowLevelDragRecordsRequestedStartAndEndPoints() async throws {
        try await TestHelpers.launchPlaygroundApp(to: "touch-control")

        _ = try await TestHelpers.waitForLabel(containing: "Touch Control Playground", timeout: 3) {
            $0 == "Touch Control Playground"
        }

        let start = (x: 250, y: 450)
        let end = (x: 250, y: 650)

        try await TestHelpers.runOffsiderCommand(
            "drag --start-x \(start.x) --start-y \(start.y) --end-x \(end.x) --end-y \(end.y) --duration 0.4 --steps 40",
            simulatorUDID: defaultSimulatorUDID
        )

        try await waitForRecordedDrag(start: start, end: end, timeout: 3)
    }

    @Test("--hold-end holds the finger still before it lifts", arguments: [("0", "Release: moving"), ("800", "Release: still")])
    func holdEnd(milliseconds: String, expected: String) async throws {
        try await TestHelpers.launchPlaygroundApp(to: "swipe-test")

        try await TestHelpers.runOffsiderCommand(
            "drag --start-x 100 --start-y 400 --end-x 300 --end-y 400 --duration 0.3 --steps 10 --hold-end \(milliseconds)",
            simulatorUDID: defaultSimulatorUDID
        )

        let release = try await TestHelpers.waitForLabel(containing: "Release:", timeout: 3) { _ in true }
        #expect(release == expected)
    }

    private func waitForRecordedDrag(
        start: (x: Int, y: Int),
        end: (x: Int, y: Int),
        timeout: TimeInterval
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        var didSeeStart = false
        var didSeeEnd = false
        var lastTouchHistory: String?

        while Date() < deadline {
            let uiState = try await TestHelpers.getUIState()
            didSeeStart = hasTouchEvent(in: uiState, type: "down", near: start)
            didSeeEnd = hasTouchEvent(in: uiState, type: "up", near: end)
            lastTouchHistory = UIStateParser.findElement(in: uiState, withIdentifier: "touch-history")?.value

            if didSeeStart && didSeeEnd {
                return
            }

            try await Task.sleep(nanoseconds: 200_000_000)
        }

        throw TestError.unexpectedState(
            "Timed out waiting for drag start (\(start.x), \(start.y)) and end (\(end.x), \(end.y)). Saw start: \(didSeeStart), saw end: \(didSeeEnd), last touch history: \(lastTouchHistory ?? "none")"
        )
    }

    private func hasTouchEvent(in uiState: UIElement, type: String, near expected: (x: Int, y: Int)) -> Bool {
        UIStateParser.findElement(in: uiState) { element in
            guard let value = element.value,
                  value.hasPrefix("\(type):"),
                  let point = CoordinateParser.parseNamedCoordinates(from: value) else {
                return false
            }

            return abs(point.x - expected.x) <= 1 && abs(point.y - expected.y) <= 1
        } != nil
    }
}
