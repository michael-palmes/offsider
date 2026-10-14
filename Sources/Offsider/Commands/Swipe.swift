import ArgumentParser
import Foundation
import OffsiderCore

struct Swipe: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Perform a swipe gesture from one point to another on the screen.",
        discussion: """
        The finger moves from the start to the end over --duration (default 1 s), a point every --delta \
        (default 50), and lifts with little or no pause, so a list may fling on. --hold-end holds it still \
        at the end for that many milliseconds before it lifts, sent as a drag, so the motion stops first, \
        as when you pause before letting go.

        Examples:
          offsider swipe --start-x 200 --start-y 600 --end-x 200 --end-y 200 --device DEVICE_ID
          offsider swipe --start-x 200 --start-y 600 --end-x 200 --end-y 200 --duration 0.3 --hold-end 400 --device DEVICE_ID
        """
    )

    static let defaultDuration: TimeInterval = 1.0
    static let defaultDelta = 50.0
    
    @Option(name: .customLong("start-x"), help: "The X coordinate of the starting point.")
    var startX: Double
    
    @Option(name: .customLong("start-y"), help: "The Y coordinate of the starting point.")
    var startY: Double
    
    @Option(name: .customLong("end-x"), help: "The X coordinate of the ending point.")
    var endX: Double
    
    @Option(name: .customLong("end-y"), help: "The Y coordinate of the ending point.")
    var endY: Double
    
    @Option(name: .customLong("duration"), help: "Duration of the swipe in seconds.")
    var duration: Double?
    
    @Option(name: .customLong("delta"), help: "Distance in points (dp on Android) between touch points.")
    var delta: Double?
    
    @Option(name: .customLong("pre-delay"), help: "Delay before starting the swipe in seconds.")
    var preDelay: Double?
    
    @Option(name: .customLong("post-delay"), help: "Delay after completing the swipe in seconds.")
    var postDelay: Double?

    @Option(name: .customLong("hold-end"), help: ArgumentHelp("Hold still this many milliseconds at the end before lifting, from 0 to 10000, so the motion stops before the release; sends the swipe as a drag.", valueName: "ms"))
    var holdEnd: Int?
    
    @OptionGroup
    var deviceOption: DeviceOption


    func validate() throws {
        // Validate coordinates are non-negative
        guard startX >= 0, startY >= 0, endX >= 0, endY >= 0 else {
            throw ValidationError("Coordinates must be non-negative values.")
        }
        guard [startX, startY, endX, endY].allSatisfy(\.isFinite) else {
            throw ValidationError("Coordinates must be finite numbers.")
        }
        
        // Validate duration if provided
        if let duration = duration {
            guard duration > 0 else {
                throw ValidationError("Duration must be greater than 0.")
            }
            guard duration <= Drag.maxDuration else {
                throw ValidationError("Duration must be at most \(Int(Drag.maxDuration)) seconds; got \(duration.formatted()).")
            }
        }
        
        // Validate delta if provided
        if let delta = delta {
            guard delta > 0 else {
                throw ValidationError("Delta must be greater than 0.")
            }
        }
        
        // Validate that start and end points are different
        guard startX != endX || startY != endY else {
            throw ValidationError("Start and end points must be different.")
        }

        if let holdEnd, !(0...10_000).contains(holdEnd) {
            throw ValidationError("--hold-end must be from 0 to 10000; got \(holdEnd).")
        }
        
        // Validate delays if provided
        if let preDelay = preDelay {
            guard preDelay >= 0 && preDelay <= 10.0 else {
                throw ValidationError("Pre-delay must be between 0 and 10 seconds.")
            }
        }
        
        if let postDelay = postDelay {
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

        let swipeDuration = duration ?? Self.defaultDuration
        let swipeDelta = delta ?? Self.defaultDelta
        
        logger.info().log("Performing swipe from (\(startX), \(startY)) to (\(endX), \(endY))")
        logger.info().log("Duration: \(swipeDuration)s, Delta: \(swipeDelta)")

        let physicalPoints = try await backend.deviceCoordinates(
            for: [(x: startX, y: startY), (x: endX, y: endY)],
            tree: nil,
            on: device
        )

        // Broadcast swipe notification for external listeners
        NotificationCenter.default.post(
            name: .hidSwipePerformed,
            object: nil,
            userInfo: [
                "startX": startX,
                "startY": startY,
                "endX": endX,
                "endY": endY,
                "duration": swipeDuration,
                "delta": swipeDelta
            ]
        )

        if let preDelay = preDelay, preDelay > 0 {
            logger.info().log("Pre-delay: \(preDelay)s")
        }
        if let postDelay = postDelay, postDelay > 0 {
            logger.info().log("Post-delay: \(postDelay)s")
        }

        let finalEvent = InputEvent.delayed(try swipeEvent(from: physicalPoints[0], to: physicalPoints[1]), pre: preDelay, post: postDelay)

        try await backend.performTracked(finalEvent, on: device)
        
        logger.info().log("Swipe gesture completed successfully")
    }
}

extension Swipe {
    /// idb's or adb's swipe, which lifts while moving; with --hold-end, a drag of the same pace that stops and holds before the lift.
    func swipeEvent(from start: (x: Double, y: Double), to end: (x: Double, y: Double)) throws -> InputEvent {
        let swipeDuration = duration ?? Self.defaultDuration
        let swipeDelta = delta ?? Self.defaultDelta
        guard let holdEnd else {
            return .swipe(start.x, yStart: start.y, xEnd: end.x, yEnd: end.y, delta: swipeDelta, duration: swipeDuration)
        }
        // Steps follow the points the caller gave, as a swipe's delta does, not the backend's input space.
        let distance = hypot(endX - startX, endY - startY)
        return try InputEvent.compositeDrag(
            from: start,
            to: end,
            duration: swipeDuration,
            steps: PixelMath.swipeSteps(distance / swipeDelta),
            initialHold: 0,
            finalHold: Double(holdEnd) / 1000
        )
    }
}

// MARK: - Notification Extension
extension Notification.Name {
    static let hidSwipePerformed = Notification.Name("hidSwipePerformed")
} 
