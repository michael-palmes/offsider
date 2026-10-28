import ArgumentParser
import Foundation
import OffsiderCore

struct Drag: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Perform a low-level point-to-point drag using explicit touch move events.",
        discussion: """
        The finger goes down at the start, holds for --hold-ms, moves in --steps even steps over --duration, \
        holds still at the end for --hold-end, then lifts. Raise --hold-ms past an app's long-press delay \
        (often 500 ms) to pick up something that drags only after a long press; `gesture long-press-drag` is \
        the same with an 800 ms hold. Raise --hold-end so a list stops without a fling, or a dragged item \
        settles over its drop target before the release.

        --screenshot-at takes a screenshot that many milliseconds after the finger comes to rest at the end, \
        before it lifts, masked as `screenshot` masks; the hold lasts until the last one unless --hold-end is set, \
        and a screenshot that runs past --hold-end keeps the finger down until it is done.

        Examples:
          offsider drag --start-x 100 --start-y 300 --end-x 100 --end-y 600 --device DEVICE_ID
          offsider drag --start-x 100 --start-y 300 --end-x 100 --end-y 600 --hold-ms 800 --device DEVICE_ID
          offsider drag --start-x 100 --start-y 300 --end-x 100 --end-y 600 --hold-end 500 --device DEVICE_ID
          offsider drag --start-x 100 --start-y 300 --end-x 100 --end-y 600 --hold-ms 800 --screenshot-at 400 --output drop.png --device DEVICE_ID
        """
    )

    private static let defaultDuration: TimeInterval = 0.6
    private static let defaultSteps = 60
    static let maxSteps = PixelMath.maxSwipeSteps
    static let maxDuration: Double = 30
    static let defaultHoldMilliseconds = 50
    static let defaultHoldEndMilliseconds = 50

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

    @Option(name: .customLong("hold-end"), help: ArgumentHelp("Milliseconds to hold still at the end before lifting, from 0 to 10000 (default 50, or until the last --screenshot-at).", valueName: "ms"))
    var holdEnd: Int?

    @Option(name: .customLong("pre-delay"), help: "Delay before starting the drag in seconds.")
    var preDelay: Double?

    @Option(name: .customLong("post-delay"), help: "Delay after completing the drag in seconds.")
    var postDelay: Double?

    @OptionGroup
    var holdShots: HoldScreenshotOptions

    @OptionGroup
    var jsonOption: InputJSONOption

    @OptionGroup
    var deviceOption: DeviceOption

    @OptionGroup
    var appOption: AppOption

    func validate() throws {
        if let problem = Coordinates.problem([("--start-x", startX), ("--start-y", startY), ("--end-x", endX), ("--end-y", endY)]) {
            throw ValidationError(problem)
        }
        guard startX >= 0, startY >= 0, endX >= 0, endY >= 0 else {
            throw ValidationError("Coordinates must be non-negative values.")
        }
        guard startX != endX || startY != endY else {
            throw ValidationError("Start and end points must be different.")
        }
        guard duration > 0 else {
            throw ValidationError("Duration must be greater than 0.")
        }
        guard duration <= Self.maxDuration else {
            throw ValidationError("Duration must be at most \(Int(Self.maxDuration)) seconds; got \(duration.formatted()).")
        }
        guard (1...Self.maxSteps).contains(steps) else {
            throw ValidationError("Steps must be between 1 and \(Self.maxSteps).")
        }
        guard (0...10_000).contains(holdMs) else {
            throw ValidationError("--hold-ms must be from 0 to 10000; got \(holdMs).")
        }
        if let holdEnd, !(0...10_000).contains(holdEnd) {
            throw ValidationError("--hold-end must be from 0 to 10000; got \(holdEnd).")
        }
        try holdShots.check(holdEnd: holdEnd)
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
        try await InputOutput.reporting(command: "drag", target: target, json: jsonOption.json) { details in
            if holdShots.isRequested { try await holdShots.prepare(command: "drag") }
            try await drag(details)
        }
    }

    /// `(100, 300) to (100, 600)`.
    var target: String {
        VerifyOutput.segmentDescription(from: (startX, startY), to: (endX, endY))
    }

    private func drag(_ details: InputDetails) async throws {
        let logger = OffsiderLogger()
        let route = try await DeviceRouter.routeForInput(deviceOption, logger: logger)
        await appOption.apply(to: route)
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

        if holdShots.isRequested {
            let end = physicalPoints[1]
            try await Console.current.progress("Dragging") {
                try await holdShots.perform(
                    press: try pressEvent(from: physicalPoints[0], to: end),
                    lift: .touch(direction: .up, x: end.x, y: end.y),
                    holdEnd: finalHoldMilliseconds,
                    on: route,
                    details: details
                )
            }
            HoldScreenshotOptions.noteOverrun(held: details.holdMs, asked: holdEnd)
        } else {
            let dragEvent = try dragEvent(from: physicalPoints[0], to: physicalPoints[1])
            try await Console.current.progress("Dragging") { try await backend.performTracked(dragEvent, on: device) }
        }

        if let postDelay, postDelay > 0 {
            logger.info().log("Post-delay: \(postDelay)s")
            try await Task.sleep(for: .seconds(postDelay))
        }

        logger.info().log("Low-level drag completed successfully")
        Console.current.show(InputPersonView.receipt(receiptHeadline))
    }

    /// `Dragged (100, 300) to (100, 600)`.
    var receiptHeadline: String {
        "Dragged \(target)"
    }

    /// Down, the --hold-ms hold, the moves, the --hold-end hold, up.
    func dragEvent(from start: (x: Double, y: Double), to end: (x: Double, y: Double)) throws -> InputEvent {
        try InputEvent.compositeDrag(
            from: start,
            to: end,
            duration: duration,
            steps: steps,
            initialHold: Double(holdMs) / 1000,
            finalHold: Double(finalHoldMilliseconds) / 1000
        )
    }

    /// Down, the --hold-ms hold and the moves, leaving the finger down at `end`, for --screenshot-at.
    func pressEvent(from start: (x: Double, y: Double), to end: (x: Double, y: Double)) throws -> InputEvent {
        try InputEvent.compositeDragPress(from: start, to: end, duration: duration, steps: steps, initialHold: Double(holdMs) / 1000)
    }

    /// --hold-end, else the default stretched to reach the last --screenshot-at.
    var finalHoldMilliseconds: Int {
        holdShots.holdEnd(given: holdEnd, fallback: Self.defaultHoldEndMilliseconds)
    }
}
