import ArgumentParser
import Foundation
import OffsiderCore

extension GesturePreset: ExpressibleByArgument {}

struct Gesture: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Perform preset gesture patterns on the simulator.",
        discussion: """
        Execute common gesture patterns without specifying coordinates.
        
        Available presets:
          scroll-up, scroll-down, scroll-left, scroll-right
          swipe-from-left-edge, swipe-from-right-edge
          swipe-from-top-edge, swipe-from-bottom-edge

        Presets are sized to the foreground app's frame from the accessibility
        tree and follow the simulator's orientation, like swipe coordinates.
        --screen-width and --screen-height override that size, in points as
        the screen is currently oriented.

        Examples:
          offsider gesture scroll-up --device DEVICE_ID
          offsider gesture scroll-down --duration 1.5 --device DEVICE_ID
          offsider gesture swipe-from-left-edge --screen-width 430 --screen-height 932 --device DEVICE_ID
        """
    )

    @Argument(help: "The gesture preset to perform.")
    var preset: GesturePreset

    @Option(name: .customLong("screen-width"), help: "Screen width in points in the current orientation (default: the app's frame width).")
    var screenWidth: Double?

    @Option(name: .customLong("screen-height"), help: "Screen height in points in the current orientation (default: the app's frame height).")
    var screenHeight: Double?
    
    @Option(name: .customLong("duration"), help: "Duration of the gesture in seconds (uses preset default if not specified).")
    var duration: Double?
    
    @Option(name: .customLong("delta"), help: "Distance between touch points in pixels (uses preset default if not specified).")
    var delta: Double?
    
    @Option(name: .customLong("pre-delay"), help: "Delay before starting the gesture in seconds.")
    var preDelay: Double?
    
    @Option(name: .customLong("post-delay"), help: "Delay after completing the gesture in seconds.")
    var postDelay: Double?
    
    @OptionGroup
    var deviceOption: DeviceOption

    func validate() throws {
        // Validate screen dimensions if provided
        if let screenWidth = screenWidth {
            guard screenWidth > 0 && screenWidth <= 2000 else {
                throw ValidationError("Screen width must be between 1 and 2000 points.")
            }
        }
        
        if let screenHeight = screenHeight {
            guard screenHeight > 0 && screenHeight <= 3000 else {
                throw ValidationError("Screen height must be between 1 and 3000 points.")
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
                throw ValidationError("Delta must be between 1 and 200 pixels.")
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

    func run() async throws {
        let logger = OffsiderLogger()
        let route = try await DeviceRouter.route(deviceOption.id, logger: logger)
        let backend = route.backend
        let device = route.device
        try await backend.prepare()

        logger.info().log("Performing \(preset.description)")
        let tree = try await backend.accessibilityTree(for: device)
        let gestureEvent = try await presetSwipe(tree: tree, backend: backend, device: device, logger: logger)

        if let preDelay = preDelay, preDelay > 0 {
            logger.info().log("Pre-delay: \(preDelay)s")
        }
        if let postDelay = postDelay, postDelay > 0 {
            logger.info().log("Post-delay: \(postDelay)s")
        }

        let finalEvent = InputEvent.delayed(gestureEvent, pre: preDelay, post: postDelay)

        try await backend.perform(finalEvent, on: device)
        
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
                errorDescription: "Unable to size the \(preset.rawValue) gesture because the accessibility tree has no application frame. Check an app is in the foreground, or run `offsider doctor --device \(device.rawValue)`."
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
