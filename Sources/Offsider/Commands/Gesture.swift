import ArgumentParser
import Foundation
import OffsiderCore

extension GesturePreset: ExpressibleByArgument {}

struct Gesture: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Perform preset gesture patterns on the device.",
        discussion: """
        Execute common gesture patterns without specifying coordinates.
        
        Available presets:
          scroll-up, scroll-down, scroll-left, scroll-right
          swipe-from-left-edge, swipe-from-right-edge
          swipe-from-top-edge, swipe-from-bottom-edge
          long-press-drag (needs --x, --y, --to-x and --to-y)

        Scroll presets are named for the finger's direction, not the content's:
          scroll-up: swipe up, moving content up to reveal what is below
          scroll-down: swipe down, moving content down to reveal what is above
          scroll-left: swipe left, moving content left to reveal what is to the right
          scroll-right: swipe right, moving content right to reveal what is to the left

        Presets are sized to the foreground app's frame from the accessibility
        tree and follow the device's orientation, like swipe coordinates.
        --screen-width and --screen-height override that size, in points
        (dp on Android) as the screen is currently oriented.

        long-press-drag presses at --x,--y, holds for --hold-ms (default 800), then drags to --to-x,--to-y \
        over --duration (default 0.6 s), for lists that reorder or tiles that move only after a long press.

        Examples:
          offsider gesture scroll-up --device DEVICE_ID
          offsider gesture long-press-drag --x 200 --y 300 --to-x 200 --to-y 600 --device DEVICE_ID
          offsider gesture scroll-down --duration 1.5 --device DEVICE_ID
          offsider gesture swipe-from-left-edge --screen-width 430 --screen-height 932 --device DEVICE_ID
        """
    )

    @Argument(help: "The gesture preset to perform; scroll presets name the finger's direction (scroll-up reveals what is below).")
    var preset: GesturePreset

    @Option(name: .customLong("screen-width"), help: "Screen width in points (dp on Android) in the current orientation (default: the app's frame width).")
    var screenWidth: Double?

    @Option(name: .customLong("screen-height"), help: "Screen height in points (dp on Android) in the current orientation (default: the app's frame height).")
    var screenHeight: Double?
    
    @Option(name: .customLong("duration"), help: "Duration of the gesture in seconds (uses preset default if not specified).")
    var duration: Double?
    
    @Option(name: .customLong("delta"), help: "Distance in points (dp on Android) between touch points (uses preset default if not specified).")
    var delta: Double?
    
    @Option(name: .customLong("x"), help: "long-press-drag: the X coordinate to press.")
    var startX: Double?

    @Option(name: .customLong("y"), help: "long-press-drag: the Y coordinate to press.")
    var startY: Double?

    @Option(name: .customLong("to-x"), help: "long-press-drag: the X coordinate to drag to.")
    var endX: Double?

    @Option(name: .customLong("to-y"), help: "long-press-drag: the Y coordinate to drag to.")
    var endY: Double?

    @Option(name: .customLong("hold-ms"), help: ArgumentHelp("long-press-drag: milliseconds to hold before moving, from 0 to 10000 (default 800).", valueName: "ms"))
    var holdMs: Int?

    @Option(name: .customLong("pre-delay"), help: "Delay before starting the gesture in seconds.")
    var preDelay: Double?
    
    @Option(name: .customLong("post-delay"), help: "Delay after completing the gesture in seconds.")
    var postDelay: Double?
    
    @OptionGroup
    var deviceOption: DeviceOption

    func validate() throws {
        try validatePoints()
        // Validate screen dimensions if provided
        if let screenWidth = screenWidth {
            guard screenWidth > 0 && screenWidth <= 2000 else {
                throw ValidationError("Screen width must be between 1 and 2000 points (dp on Android).")
            }
        }
        
        if let screenHeight = screenHeight {
            guard screenHeight > 0 && screenHeight <= 3000 else {
                throw ValidationError("Screen height must be between 1 and 3000 points (dp on Android).")
            }
        }
        
        // Validate duration if provided
        if let duration = duration {
            guard duration > 0 && duration <= 10.0 else {
                throw ValidationError("Duration must be between 0 and 10 seconds.")
            }
        }
        
        // Validate delta if provided
        if let delta = delta {
            guard delta > 0 && delta <= 200 else {
                throw ValidationError("Delta must be between 1 and 200 points (dp on Android).")
            }
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

    private func validatePoints() throws {
        let points = [("--x", startX), ("--y", startY), ("--to-x", endX), ("--to-y", endY)]
        guard preset.kind == .longPressDrag else {
            for (name, value) in points where value != nil {
                throw ValidationError("\(name) applies to long-press-drag only.")
            }
            if holdMs != nil { throw ValidationError("--hold-ms applies to long-press-drag only.") }
            return
        }
        let missing = points.filter { $0.1 == nil }.map(\.0)
        guard missing.isEmpty else {
            throw ValidationError("long-press-drag needs \(missing.joined(separator: ", ")).")
        }
        guard points.allSatisfy({ ($0.1 ?? 0) >= 0 }) else {
            throw ValidationError("Coordinates must be non-negative values.")
        }
        guard startX != endX || startY != endY else {
            throw ValidationError("The start and end points must be different.")
        }
        for (name, isSet) in [("--screen-width", screenWidth != nil), ("--screen-height", screenHeight != nil), ("--delta", delta != nil)] where isSet {
            throw ValidationError("\(name) applies to swipe presets only, not long-press-drag.")
        }
        if let holdMs, !(0...10_000).contains(holdMs) {
            throw ValidationError("--hold-ms must be from 0 to 10000; got \(holdMs).")
        }
    }

    /// The preset's input: a sized swipe, or a held press and drag between the given points.
    @MainActor
    func presetEvent(tree: @MainActor () async throws -> UITree, backend: any DeviceBackend, device: DeviceID, logger: OffsiderLogger) async throws -> InputEvent {
        guard preset.kind == .longPressDrag else {
            return try await presetSwipe(tree: try await tree(), backend: backend, device: device, logger: logger)
        }
        return try await presetDrag(backend: backend, device: device)
    }

    @MainActor
    func presetDrag(backend: any DeviceBackend, device: DeviceID) async throws -> InputEvent {
        let points = try await backend.deviceCoordinates(
            for: [(x: startX ?? 0, y: startY ?? 0), (x: endX ?? 0, y: endY ?? 0)],
            tree: nil,
            on: device
        )
        return try InputEvent.compositeDrag(
            from: points[0],
            to: points[1],
            duration: duration ?? preset.defaultDuration,
            steps: GesturePreset.dragSteps,
            initialHold: Double(holdMs ?? GesturePreset.defaultHoldMilliseconds) / 1000,
            finalHold: 0.05
        )
    }

    func run() async throws {
        let logger = OffsiderLogger()
        let route = try await DeviceRouter.routeForInput(deviceOption, logger: logger)
        let backend = route.backend
        let device = route.device
        try await backend.prepare()

        logger.info().log("Performing \(preset.description)")
        let gestureEvent = try await presetEvent(tree: { try await backend.accessibilityTree(for: device) }, backend: backend, device: device, logger: logger)

        if let preDelay = preDelay, preDelay > 0 {
            logger.info().log("Pre-delay: \(preDelay)s")
        }
        if let postDelay = postDelay, postDelay > 0 {
            logger.info().log("Post-delay: \(postDelay)s")
        }

        let finalEvent = InputEvent.delayed(gestureEvent, pre: preDelay, post: postDelay)

        try await backend.performTracked(finalEvent, on: device)
        
        logger.info().log("Gesture completed successfully")
    }

    /// The preset as a swipe in the backend's input space, sized to the app frame in `tree`.
    @MainActor
    func presetSwipe(
        tree: UITree,
        backend: any DeviceBackend,
        device: DeviceID,
        logger: OffsiderLogger
    ) async throws -> InputEvent {
        guard let applicationFrame = tree.applicationFrame else {
            throw CLIError(
                errorDescription: "Unable to size the \(preset.rawValue) gesture because the accessibility tree has no application frame. Check an app is in the foreground, or run `offsider doctor --device \(device.rawValue)`.",
                reason: .treeReadFailed
            )
        }
        let screen = GesturePreset.screen(applicationFrame: applicationFrame, width: screenWidth, height: screenHeight)
        let (start, end) = preset.endpoints(in: screen)
        let gestureDuration = duration ?? preset.defaultDuration
        let gestureDelta = delta ?? preset.defaultDelta

        logger.info().log("Screen size: \(screen.width)x\(screen.height)")
        logger.info().log("Coordinates: (\(start.x), \(start.y)) to (\(end.x), \(end.y))")
        logger.info().log("Duration: \(gestureDuration)s, Delta: \(gestureDelta)px")

        let physicalPoints = try await backend.deviceCoordinates(
            for: [(x: start.x, y: start.y), (x: end.x, y: end.y)],
            tree: tree,
            on: device
        )
        let physicalStart = physicalPoints[0]
        let physicalEnd = physicalPoints[1]

        return .swipe(
            physicalStart.x,
            yStart: physicalStart.y,
            xEnd: physicalEnd.x,
            yEnd: physicalEnd.y,
            delta: gestureDelta,
            duration: gestureDuration
        )
    }
}
