import ArgumentParser
import Foundation
import OffsiderCore

struct Drag: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Perform a low-level point-to-point drag using explicit touch move events.",
        discussion: """
        The finger goes down at the start, holds for --hold-ms, moves in --steps even steps over --duration, \
        then lifts at the end. Raise --hold-ms past an app's long-press delay (often 500 ms) to pick up \
        something that drags only after a long press; `gesture long-press-drag` is the same with an 800 ms hold.

        Examples:
          offsider drag --start-x 100 --start-y 300 --end-x 100 --end-y 600 --device DEVICE_ID
          offsider drag --start-x 100 --start-y 300 --end-x 100 --end-y 600 --hold-ms 800 --device DEVICE_ID
        """
    )

    private static let defaultDuration: TimeInterval = 0.6
    private static let defaultSteps = 60
    private static let maxSteps = 1_000
    static let defaultHoldMilliseconds = 50
    private static let finalHold: TimeInterval = 0.05

    @Option(name: .customLong("start-x"), help: "The X coordinate of the starting point.")
    var startX: Double

    @Option(name: .customLong("start-y"), help: "The Y coordinate of the starting point.")
    var startY: Double

    @Option(name: .customLong("end-x"), help: "The X coordinate of the ending point.")
    var endX: Double

    @Option(name: .customLong("end-y"), help: "The Y coordinate of the ending point.")
    var endY: Double

    @Option(name: .customLong("duration"), help: "Duration of the drag movement in seconds.")
    var duration: Double = Self.defaultDuration

    @Option(name: .customLong("steps"), help: "Number of touch move events to emit during the drag.")
    var steps: Int = Self.defaultSteps

    @Option(name: .customLong("hold-ms"), help: ArgumentHelp("Milliseconds to hold at the start before moving, from 0 to 10000; 500 or more starts a long-press drag.", valueName: "ms"))
    var holdMs: Int = Self.defaultHoldMilliseconds

    @Option(name: .customLong("pre-delay"), help: "Delay before starting the drag in seconds.")
    var preDelay: Double?

    @Option(name: .customLong("post-delay"), help: "Delay after completing the drag in seconds.")
    var postDelay: Double?

    @OptionGroup
    var deviceOption: DeviceOption

    func validate() throws {
        guard startX >= 0, startY >= 0, endX >= 0, endY >= 0 else {
            throw ValidationError("Coordinates must be non-negative values.")
        }
        guard startX != endX || startY != endY else {
            throw ValidationError("Start and end points must be different.")
        }
        guard duration > 0 else {
            throw ValidationError("Duration must be greater than 0.")
        }
        guard (1...Self.maxSteps).contains(steps) else {
            throw ValidationError("Steps must be between 1 and \(Self.maxSteps).")
        }
        guard (0...10_000).contains(holdMs) else {
            throw ValidationError("--hold-ms must be from 0 to 10000; got \(holdMs).")
        }
        if let preDelay {
            guard preDelay >= 0 && preDelay <= 10.0 else {
                throw ValidationError("Pre-delay must be between 0 and 10 seconds.")
            }
        }
        if let postDelay {
            guard postDelay >= 0 && postDelay <= 10.0 else {
                throw ValidationError("Post-delay must be between 0 and 10 seconds.")
            }
        }
    }

    func run() async throws {
        let logger = OffsiderLogger()
        let route = try await DeviceRouter.routeForInput(deviceOption, logger: logger)
        let backend = route.backend
        let device = route.device
        try await backend.prepare()

        logger.info().log("Performing low-level drag from (\(startX), \(startY)) to (\(endX), \(endY))")
        logger.info().log("Duration: \(duration)s, steps: \(steps)")

        if let preDelay, preDelay > 0 {
            logger.info().log("Pre-delay: \(preDelay)s")
            try await Task.sleep(for: .seconds(preDelay))
        }

        let physicalPoints = try await backend.deviceCoordinates(
            for: [(x: startX, y: startY), (x: endX, y: endY)],
            tree: nil,
            on: device
        )

        let dragEvent = try dragEvent(from: physicalPoints[0], to: physicalPoints[1])
        try await backend.performTracked(dragEvent, on: device)

        if let postDelay, postDelay > 0 {
            logger.info().log("Post-delay: \(postDelay)s")
            try await Task.sleep(for: .seconds(postDelay))
        }

        logger.info().log("Low-level drag completed successfully")
    }

    /// Down, the --hold-ms hold, the moves, a short hold, up.
    func dragEvent(from start: (x: Double, y: Double), to end: (x: Double, y: Double)) throws -> InputEvent {
        try InputEvent.compositeDrag(
            from: start,
            to: end,
            duration: duration,
            steps: steps,
            initialHold: Double(holdMs) / 1000,
            finalHold: Self.finalHold
        )
    }
}
