import Testing
import Foundation
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
