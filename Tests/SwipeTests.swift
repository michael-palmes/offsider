import Foundation
import OffsiderCore
import Testing
@testable import Offsider

@Suite("Swipe hold at the end")
@MainActor
struct SwipeHoldEndTests {
    private static func swipe(_ arguments: [String]) throws -> Swipe {
        try Swipe.parse(["--start-x", "200", "--start-y", "800", "--end-x", "200", "--end-y", "400"] + arguments + ["--device", "emulator-5554"])
    }

    @Test("without --hold-end a swipe stays one swipe event, which lifts while moving")
    func plainSwipeStaysSwipe() throws {
        let event = try Self.swipe(["--duration", "0.4"]).swipeEvent(from: (x: 200, y: 800), to: (x: 200, y: 400))

        #expect(event == .swipe(200, yStart: 800, xEnd: 200, yEnd: 400, delta: 50, duration: 0.4))
    }

    @Test("--hold-end sends a drag: down at the start with no hold, moves over --duration, the hold at the end point, then up there")
    func holdEndIsDrag() throws {
        let event = try Self.swipe(["--duration", "0.4", "--hold-end", "500"]).swipeEvent(from: (x: 200, y: 800), to: (x: 200, y: 400))

        guard case .composite(let events) = event else {
            Issue.record("expected a composite drag, got \(event)")
            return
        }
        #expect(events.first == .touch(direction: .down, x: 200, y: 800))
        #expect(events.suffix(3) == [.touch(direction: .down, x: 200, y: 400), .delay(0.5), .touch(direction: .up, x: 200, y: 400)])
        let delays = events.compactMap { if case .delay(let seconds) = $0 { return seconds } else { return nil } }
        #expect(delays.first == 0)
        #expect(abs(delays.dropFirst().dropLast().reduce(0, +) - 0.4) < 1e-9)
        #expect(events.filter { if case .touch(.down, _, _) = $0 { return true } else { return false } }.count > 2)
    }

    @Test("--hold-end with a tiny --delta moves in at most drag's 1000 steps, not one per fraction of a point")
    func holdEndCapsSteps() throws {
        let event = try Self.swipe(["--delta", "0.01", "--hold-end", "100"]).swipeEvent(from: (x: 200, y: 800), to: (x: 200, y: 400))

        guard case .composite(let events) = event else {
            Issue.record("expected a composite drag, got \(event)")
            return
        }
        let moves = events.filter { if case .touch(.down, _, _) = $0 { return true } else { return false } }.count
        #expect(moves <= Drag.maxSteps + 2)
    }

    @Test("--hold-end outside 0 to 10000 is a usage error", arguments: ["-1", "10001"])
    func holdEndRange(value: String) {
        let error = #expect(throws: (any Error).self) { try Self.swipe(["--hold-end=\(value)"]) }
        #expect(error.map { Swipe.message(for: $0).contains("--hold-end must be from 0 to 10000") } == true)
    }

    @Test("a batch swipe step sends the command's event, with and without --hold-end", arguments: [[], ["--hold-end", "300"]])
    func batchMatchesCommand(extra: [String]) async throws {
        let device = DeviceID(rawValue: "STUB", platform: .ios)
        let context = BatchContext(backend: StubBackend(session: RecordingInputSession()), device: device, axCachePolicy: .perBatch, typeSubmissionMode: .composite, typeChunkSize: 1)
        let step = try Self.swipe(extra)

        let primitives = try await step.toBatchPrimitives(context: context, logger: OffsiderLogger())

        #expect(primitives.count == 1)
        guard case .hidMergeable(let event) = primitives.first else {
            Issue.record("expected a mergeable event, got \(primitives)")
            return
        }
        #expect(event == (try step.swipeEvent(from: (x: 200, y: 800), to: (x: 200, y: 400))))
    }
}

@Suite("Swipe Command Tests", .serialized, .enabled(if: isE2EEnabled))
struct SwipeTests {
    @Test("Basic swipe registers on screen")
    func basicSwipe() async throws {
        // Arrange
        try await TestHelpers.launchPlaygroundApp(to: "swipe-test")
        try await Task.sleep(nanoseconds: 1_000_000_000) // Extra wait for app to be ready
        
        // Act
        try await TestHelpers.runOffsiderCommand("swipe --start-x 100 --start-y 400 --end-x 300 --end-y 400", simulatorUDID: defaultSimulatorUDID)
        try await Task.sleep(nanoseconds: 1_000_000_000)
        
        // Assert
        let uiState = try await TestHelpers.getUIState()
        let swipeCount = UIStateParser.findElementContainingLabel(in: uiState, containing: "Count:")
        let startElement = UIStateParser.findElementContainingLabel(in: uiState, containing: "Start:")
        let endElement = UIStateParser.findElementContainingLabel(in: uiState, containing: "End:")

        #expect(swipeCount?.label == "Count: 1")
        #expect(startElement?.label == "Start: (100, 400)")
        #expect(endElement?.label == "End: (300, 400)")
    }
    
    @Test("A fast swipe lifts while moving, and --hold-end stops the finger before it lifts", arguments: [("", "Release: moving"), (" --hold-end 800", "Release: still")])
    func holdEndReleasesStill(extra: String, expected: String) async throws {
        try await TestHelpers.launchPlaygroundApp(to: "swipe-test")

        try await TestHelpers.runOffsiderCommand("swipe --start-x 100 --start-y 400 --end-x 300 --end-y 400 --duration 0.2 --delta 10\(extra)", simulatorUDID: defaultSimulatorUDID)

        let release = try await TestHelpers.waitForLabel(containing: "Release:", timeout: 3) { _ in true }
        #expect(release == expected)
        #expect(UIStateParser.findElementContainingLabel(in: try await TestHelpers.getUIState(), containing: "End:")?.label == "End: (300, 400)")
    }

    @Test("Landscape coordinate swipe preserves translated start and end", .enabled(if: isLandscapeE2EEnabled))
    func landscapeCoordinateSwipePreservesTranslatedStartAndEnd() async throws {
        try await TestHelpers.launchPlaygroundApp(to: "landscape-coordinate-test")
        do {
            try await TestHelpers.resetLandscapeCoordinateFixtureToPortrait()
            try await TestHelpers.setSimulatorOrientationLandscapeLeft()

            let initialState = try await TestHelpers.waitForLandscapeCoordinateFixtureLayout(timeout: 6)

            guard let start = UIStateParser.findElementByLabel(in: initialState, label: "Landscape Swipe Start"),
                  let startFrame = start.frame,
                  let end = UIStateParser.findElementByLabel(in: initialState, label: "Landscape Swipe End"),
                  let endFrame = end.frame else {
                throw TestError.elementNotFound("landscape-coordinate-swipe-targets")
            }

            let startX = Int(startFrame.x + startFrame.width / 2)
            let startY = Int(startFrame.y + startFrame.height / 2)
            let endX = Int(endFrame.x + endFrame.width / 2)
            let endY = Int(endFrame.y + endFrame.height / 2)

            try await TestHelpers.runOffsiderCommand(
                "swipe --start-x \(startX) --start-y \(startY) --end-x \(endX) --end-y \(endY) --duration 0.3 --delta 10",
                simulatorUDID: defaultSimulatorUDID
            )

            let hitCount = try await waitForLandscapeSwipeHitCount(expected: "Landscape Swipe Hit Count: 1", timeout: 3)
            #expect(hitCount == "Landscape Swipe Hit Count: 1")
            try await assertLastNamedCoordinate(containing: "Last Swipe Start:", expectedX: startX, expectedY: startY, timeout: 3)
            try await assertLastNamedCoordinate(containing: "Last Swipe End:", expectedX: endX, expectedY: endY, timeout: 3)
            try await TestHelpers.resetLandscapeCoordinateFixtureToPortrait()
        } catch {
            try? await TestHelpers.resetLandscapeCoordinateFixtureToPortrait()
            throw error
        }
    }

    @Test("Landscape-right coordinate swipe preserves translated start and end", .enabled(if: isLandscapeE2EEnabled))
    func landscapeRightCoordinateSwipePreservesTranslatedStartAndEnd() async throws {
        try await TestHelpers.launchPlaygroundApp(to: "landscape-coordinate-test")
        do {
            try await TestHelpers.resetLandscapeCoordinateFixtureToPortrait()
            try await TestHelpers.setSimulatorOrientationLandscapeRight()

            let initialState = try await TestHelpers.waitForLandscapeCoordinateFixtureLayout(timeout: 6)

            guard let start = UIStateParser.findElementByLabel(in: initialState, label: "Landscape Swipe Start"),
                  let startFrame = start.frame,
                  let end = UIStateParser.findElementByLabel(in: initialState, label: "Landscape Swipe End"),
                  let endFrame = end.frame else {
                throw TestError.elementNotFound("landscape-coordinate-swipe-targets")
            }

            let startX = Int(startFrame.x + startFrame.width / 2)
            let startY = Int(startFrame.y + startFrame.height / 2)
            let endX = Int(endFrame.x + endFrame.width / 2)
            let endY = Int(endFrame.y + endFrame.height / 2)

            try await TestHelpers.runOffsiderCommand(
                "swipe --start-x \(startX) --start-y \(startY) --end-x \(endX) --end-y \(endY) --duration 0.3 --delta 10",
                simulatorUDID: defaultSimulatorUDID
            )

            let hitCount = try await waitForLandscapeSwipeHitCount(expected: "Landscape Swipe Hit Count: 1", timeout: 3)
            #expect(hitCount == "Landscape Swipe Hit Count: 1")
            try await assertLastNamedCoordinate(containing: "Last Swipe Start:", expectedX: startX, expectedY: startY, timeout: 3)
            try await assertLastNamedCoordinate(containing: "Last Swipe End:", expectedX: endX, expectedY: endY, timeout: 3)
            try await TestHelpers.resetLandscapeCoordinateFixtureToPortrait()
        } catch {
            try? await TestHelpers.resetLandscapeCoordinateFixtureToPortrait()
            throw error
        }
    }

    @Test("Swipe direction detection", arguments: [
        (start: (100, 400), end: (300, 400), direction: "Right"),
        (start: (300, 400), end: (100, 400), direction: "Left"),
        (start: (200, 300), end: (200, 500), direction: "Down"),
        (start: (200, 500), end: (200, 300), direction: "Up")
    ])
    func swipeDirectionDetection(
        _ swipeTest: (start: (Int, Int), end: (Int, Int), direction: String)
    ) async throws {
        // Arrange
        try await TestHelpers.launchPlaygroundApp(to: "swipe-test")
        try await Task.sleep(nanoseconds: 1_000_000_000) // Extra wait for app to be ready
        
        // Act
        try await TestHelpers.runOffsiderCommand(
            "swipe --start-x \(swipeTest.start.0) --start-y \(swipeTest.start.1) --end-x \(swipeTest.end.0) --end-y \(swipeTest.end.1)",
            simulatorUDID: defaultSimulatorUDID
        )
        try await Task.sleep(nanoseconds: 1_000_000_000)
        
        // Assert
        let uiState = try await TestHelpers.getUIState()
        let directionElement = UIStateParser.findElementContainingLabel(in: uiState, containing: "Direction:")
        #expect(directionElement != nil, "Should find direction element")
        #expect(directionElement?.label == "Direction: \(swipeTest.direction)", 
                "Direction should be \(swipeTest.direction)")
    }
    
    @Test("Swipe with custom duration")
    func swipeWithDuration() async throws {
        // Arrange
        try await TestHelpers.launchPlaygroundApp(to: "swipe-test")
        
        // Act - slower swipe (2 seconds)
        let startTime = Date()
        try await TestHelpers.runOffsiderCommand("swipe --start-x 100 --start-y 400 --end-x 300 --end-y 400 --duration 2", simulatorUDID: defaultSimulatorUDID)
        let endTime = Date()
        
        // Assert
        let duration = endTime.timeIntervalSince(startTime)
        #expect(duration >= 2.0, "Swipe should take at least 2 seconds")
        
        let uiState = try await TestHelpers.getUIState()
        let swipeCountElement = UIStateParser.findElementContainingLabel(in: uiState, containing: "Count:")
        #expect(swipeCountElement?.label == "Count: 1", "Swipe should still register with custom duration")
    }
    
    @Test("Multiple swipes register correctly")
    func multipleSwipes() async throws {
        // Arrange
        try await TestHelpers.launchPlaygroundApp(to: "swipe-test")
        let swipeCount = 3
        
        // Act
        for i in 1...swipeCount {
            try await TestHelpers.runOffsiderCommand("swipe --start-x \(100 + i * 30) --start-y \(400 + i * 20) --end-x \(200 + i * 30) --end-y \(400 + i * 20)", simulatorUDID: defaultSimulatorUDID)
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        
        try await Task.sleep(nanoseconds: 500_000_000)
        
        // Assert
        let uiState = try await TestHelpers.getUIState()
        let swipeCountElement = UIStateParser.findElementContainingLabel(in: uiState, containing: "Count:")
        #expect(swipeCountElement?.label == "Count: \(swipeCount)", "Swipe count should be \(swipeCount)")
    }
    
    private func waitForLandscapeSwipeHitCount(expected: String, timeout: TimeInterval) async throws -> String {
        let deadline = Date().addingTimeInterval(timeout)
        var lastValue: String?

        while Date() < deadline {
            let uiState = try await TestHelpers.getUIState()
            if let element = UIStateParser.findElementContainingLabel(in: uiState, containing: "Landscape Swipe Hit Count:"),
               let label = element.label {
                lastValue = label
                if label == expected {
                    return label
                }
            }
            try await Task.sleep(nanoseconds: 200_000_000)
        }

        throw TestError.unexpectedState("Timed out waiting for \(expected). Last value: \(lastValue ?? "none")")
    }

    private func assertLastNamedCoordinate(
        containing text: String,
        expectedX: Int,
        expectedY: Int,
        timeout: TimeInterval
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        var lastValue: String?

        while Date() < deadline {
            let uiState = try await TestHelpers.getUIState()
            if let label = UIStateParser.findElementContainingLabel(in: uiState, containing: text)?.label {
                lastValue = label
                if let point = CoordinateParser.parseNamedCoordinates(from: label),
                   abs(point.x - expectedX) <= 1,
                   abs(point.y - expectedY) <= 1 {
                    return
                }
            }
            try await Task.sleep(nanoseconds: 200_000_000)
        }

        throw TestError.unexpectedState(
            "Timed out waiting for \(text) near x:\(expectedX),y:\(expectedY). Last value: \(lastValue ?? "none")"
        )
    }

    @Test("Draw complex shapes")
    func swipeSegmentedStarTenPaths() async throws {
        // Arrange
        try await TestHelpers.launchPlaygroundApp(to: "swipe-test")
        try await Task.sleep(nanoseconds: 1_000_000_000) // Extra wait for app to be ready
        
        // Act - Draw a proper 5-pointed star broken into 10 segments
        // Star centered at (200, 300) with appropriate radius
        
        // Calculate the 10 vertices of a 5-pointed star
        // We alternate between outer points (tips) and inner vertices
        let centerX = 200.0
        let centerY = 400.0  // Move down to have more space
        let outerRadius = 150.0  // Much larger star
        let innerRadius = 60.0   // Proportionally larger inner radius
        
        var vertices: [(x: Int, y: Int)] = []
        
        // Generate 10 vertices - alternating between outer and inner points
        for i in 0..<10 {
            let angle = Double(i) * .pi / 5.0 - .pi / 2.0  // Start from top
            let radius = i % 2 == 0 ? outerRadius : innerRadius
            
            let x = centerX + radius * cos(angle)
            let y = centerY + radius * sin(angle)
            
            vertices.append((x: Int(x), y: Int(y)))
        }
        
        // Draw the star as 10 segments with gaps between them
        // Each segment connects adjacent vertices
        for i in 0..<10 {
            let startVertex = vertices[i]
            let endVertex = vertices[(i + 1) % 10]
            
            // Calculate midpoints for creating gaps
            let gapSize = 0.10  // 10% gap at each end (smaller gap for larger star)
            let midStartX = Int(Double(startVertex.x) + (Double(endVertex.x - startVertex.x) * gapSize))
            let midStartY = Int(Double(startVertex.y) + (Double(endVertex.y - startVertex.y) * gapSize))
            let midEndX = Int(Double(endVertex.x) - (Double(endVertex.x - startVertex.x) * gapSize))
            let midEndY = Int(Double(endVertex.y) - (Double(endVertex.y - startVertex.y) * gapSize))
            
            // Draw segment with gap - use smaller delta for better detection
            try await TestHelpers.runOffsiderCommand(
                "swipe --start-x \(midStartX) --start-y \(midStartY) --end-x \(midEndX) --end-y \(midEndY) --duration 0.3 --delta 10",
                simulatorUDID: defaultSimulatorUDID
            )
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        
        try await Task.sleep(nanoseconds: 1_000_000_000)
        
        // Assert - Verify all 10 swipes were registered for proper star
        let uiState = try await TestHelpers.getUIState()
        let swipeCountElement = UIStateParser.findElementContainingLabel(in: uiState, containing: "Count:")
        
        // The swipe count element should always exist
        #expect(swipeCountElement != nil, "Should find swipe count element")
        
        // Verify exactly 10 swipes were registered
        #expect(swipeCountElement?.label == "Count: 10", "Should have registered 10 swipes for segmented star art, but got: \(swipeCountElement?.label ?? "nil")")
    }
}
