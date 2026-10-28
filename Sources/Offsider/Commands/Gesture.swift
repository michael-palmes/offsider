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
          swipe-from-top-edge (Notification Centre, Android's notification shade)
          swipe-from-top-right-edge (Control Centre)
          swipe-from-bottom-edge (home on Android)
          long-press-drag (needs --x, --y, --to-x and --to-y)
          pinch (needs --from and --to)

        Scroll presets are named for the finger's direction, not the content's:
          scroll-up: swipe up, moving content up to reveal what is below
          scroll-down: swipe down, moving content down to reveal what is above
          scroll-left: swipe left, moving content left to reveal what is to the right
          scroll-right: swipe right, moving content right to reveal what is to the left

        Top and bottom swipes start 2 points inside the screen's edge, clear of a
        Dynamic Island; left and right swipes start 20 points inside the foreground
        app's frame, where its back swipe begins, and scrolls run through its middle.
        All follow the device's orientation, like swipe coordinates.
        --screen-width and --screen-height override that size, in points
        (dp on Android) as the screen is currently oriented.

        On an iOS simulator a swipe up from the bottom edge reaches the app, not the
        system: use `button home` or `button app-switch` to leave the app.

        long-press-drag presses at --x,--y, holds for --hold-ms (default 800), then drags to --to-x,--to-y \
        over --duration (default 0.6 s), for lists that reorder or tiles that move only after a long press.

        pinch puts two fingers --from points apart on a horizontal line through --x,--y (default the middle of \
        the app's frame), moves them to --to points apart over --duration (default 0.5 s, from 0.1 to 10) and \
        lifts them: --to above --from spreads them (zoom in), below squeezes them (zoom out). Spreads are 20 to \
        600 points, and both fingers must stay on the screen. An iOS simulator's main display and Android \
        emulators and phones take it (gRPC, or the UiAutomation helper); a physical iPhone and the iPhone Duo's \
        inner display refuse it.

        Examples:
          offsider gesture scroll-up --device DEVICE_ID
          offsider gesture long-press-drag --x 200 --y 300 --to-x 200 --to-y 600 --device DEVICE_ID
          offsider gesture pinch --from 60 --to 240 --device DEVICE_ID
          offsider gesture pinch --from 240 --to 60 --x 200 --y 400 --duration 0.8 --device DEVICE_ID
          offsider gesture scroll-down --duration 1.5 --device DEVICE_ID
          offsider gesture swipe-from-top-right-edge --device DEVICE_ID
          offsider gesture swipe-from-left-edge --screen-width 430 --screen-height 932 --device DEVICE_ID
        """
    )

    @Argument(help: "The gesture preset to perform; scroll presets name the finger's direction (scroll-up reveals what is below).")
    var preset: GesturePreset

    @Option(name: .customLong("screen-width"), help: "Screen width in points (dp on Android) in the current orientation (default: the screen's for top and bottom swipes, else the app frame's).")
    var screenWidth: Double?

    @Option(name: .customLong("screen-height"), help: "Screen height in points (dp on Android) in the current orientation (default: the screen's for top and bottom swipes, else the app frame's).")
    var screenHeight: Double?
    
    @Option(name: .customLong("duration"), help: "Duration of the gesture in seconds (uses preset default if not specified).")
    var duration: Double?
    
    @Option(name: .customLong("delta"), help: "Distance in points (dp on Android) between touch points (uses preset default if not specified).")
    var delta: Double?
    
    @Option(name: .customLong("x"), help: "long-press-drag: the X coordinate to press; pinch: the centre's (default the app frame's middle).")
    var startX: Double?

    @Option(name: .customLong("y"), help: "long-press-drag: the Y coordinate to press; pinch: the centre's (default the app frame's middle).")
    var startY: Double?

    @Option(help: ArgumentHelp("pinch: points between the fingers at the start, from 20 to 600.", valueName: "points"))
    var from: Double?

    @Option(help: ArgumentHelp("pinch: points between the fingers at the end, from 20 to 600; above --from zooms in.", valueName: "points"))
    var to: Double?

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
    var jsonOption: InputJSONOption

    @OptionGroup
    var deviceOption: DeviceOption

    @OptionGroup
    var appOption: AppOption

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

    private func validatePinch() throws {
        for (name, isSet) in [("--to-x", endX != nil), ("--to-y", endY != nil), ("--hold-ms", holdMs != nil), ("--delta", delta != nil), ("--screen-width", screenWidth != nil), ("--screen-height", screenHeight != nil)] where isSet {
            throw ValidationError("\(name) does not apply to pinch.")
        }
        guard let from, let to else { throw ValidationError("pinch needs --from and --to, the points between the fingers at the start and end.") }
        if let problem = Coordinates.problem([("--from", from), ("--to", to), ("--x", startX), ("--y", startY)]) { throw ValidationError(problem) }
        for (name, value) in [("--from", from), ("--to", to)] where !GesturePreset.pinchSpreads.contains(value) {
            throw ValidationError("\(name) must be from 20 to 600 points; got \(value.formatted()).")
        }
        guard from != to else { throw ValidationError("--from and --to must differ: the fingers move apart or together.") }
        guard (startX == nil) == (startY == nil) else { throw ValidationError("Give both --x and --y for the pinch's centre, or neither.") }
        guard (startX ?? 0) >= 0, (startY ?? 0) >= 0 else { throw ValidationError("Coordinates must be non-negative values.") }
        if let duration, !GesturePreset.pinchDurations.contains(duration) {
            throw ValidationError("--duration must be from 0.1 to 10 seconds for pinch; got \(duration.formatted()).")
        }
    }

    private func validatePoints() throws {
        if preset.kind == .pinch { return try validatePinch() }
        if from != nil || to != nil { throw ValidationError("--from and --to apply to pinch only.") }
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
        if let problem = Coordinates.problem(points) {
            throw ValidationError(problem)
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
        if preset.kind == .pinch { return try await presetPinch(tree: tree, backend: backend, device: device) }
        guard preset.kind == .longPressDrag else {
            // Sizing to the screen and mapping the points then read the simulator's orientation once.
            return try await SimulatorOrientationReader.$sharedReadings.withValue(SimulatorOrientationReader.SharedReadings()) {
                try await presetSwipe(tree: try await tree(), backend: backend, device: device, logger: logger)
            }
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

    /// Two fingers about the centre, each frame checked on screen, then mapped to the backend's input space in one call.
    @MainActor
    func presetPinch(tree: @MainActor () async throws -> UITree, backend: any DeviceBackend, device: DeviceID) async throws -> InputEvent {
        let centre: UIPoint
        if let startX, let startY {
            centre = UIPoint(x: startX, y: startY)
        } else {
            guard let frame = try await tree().applicationFrame else {
                throw CLIError(
                    errorDescription: "Unable to centre the pinch because the accessibility tree has no application frame. Pass --x and --y, or check an app is in the foreground.",
                    reason: .treeReadFailed
                )
            }
            centre = UIPoint(x: frame.x + frame.width / 2, y: frame.y + frame.height / 2)
        }
        let screen = try await backend.screenSize(for: device)
        for spread in [from ?? 0, to ?? 0] {
            _ = try Touch.fingerPoints(x: centre.x, y: centre.y, spread: spread, screen: screen, fix: "Move --x, or bring --from and --to closer together.")
        }
        let duration = duration ?? preset.defaultDuration
        let frames = GesturePreset.pinchFrames(centre: centre, from: from ?? 0, to: to ?? 0, moves: GesturePreset.pinchMoves(duration: duration))
        let mapped = try await backend.deviceCoordinates(for: frames.flatMap { [(x: $0.0.x, y: $0.0.y), (x: $0.1.x, y: $0.1.y)] }, tree: nil, on: device)
        let pairs = stride(from: 0, to: mapped.count - 1, by: 2).map { (first: mapped[$0], second: mapped[$0 + 1]) }
        return InputEvent.compositePinch(frames: pairs, duration: duration)
    }

    func run() async throws {
        try await InputOutput.reporting(command: "gesture", target: preset.rawValue, json: jsonOption.json) { _ in try await send() }
    }

    private func send() async throws {
        let logger = OffsiderLogger()
        let route = try await DeviceRouter.routeForInput(deviceOption, logger: logger)
        await appOption.apply(to: route)
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

        try await Console.current.progress("Sending \(preset.rawValue)") { try await backend.performTracked(finalEvent, on: device) }

        logger.info().log("Gesture completed successfully")
        Console.current.show(InputPersonView.receipt("Sent \(preset.rawValue)", aside: receiptAside))
    }

    /// long-press-drag names its two points and pinch its spreads; a swipe preset sizes itself, so it needs none.
    var receiptAside: String? {
        if preset.kind == .pinch, let from, let to {
            return "\(VerifyOutput.number(from)) to \(VerifyOutput.number(to)) points apart" + (startX.flatMap { x in startY.map { " at \(VerifyOutput.pointDescription(x: x, y: $0))" } } ?? "")
        }
        guard preset.kind == .longPressDrag, let startX, let startY, let endX, let endY else { return nil }
        return "\(VerifyOutput.pointDescription(x: startX, y: startY)) to \(VerifyOutput.pointDescription(x: endX, y: endY))"
    }

    /// The preset as a swipe in the backend's input space: top and bottom swipes sized to the screen, the rest to the app frame in `tree`.
    @MainActor
    func presetSwipe(
        tree: UITree,
        backend: any DeviceBackend,
        device: DeviceID,
        logger: OffsiderLogger
    ) async throws -> InputEvent {
        let screenSize = preset.spansScreen && (screenWidth == nil || screenHeight == nil)
            ? await Timings.measure("screen-size") { try? await backend.screenSize(for: device) }
            : nil
        guard let screen = preset.frame(screen: screenSize, viewport: tree.viewport, applicationFrame: tree.applicationFrame, width: screenWidth, height: screenHeight) else {
            throw CLIError(
                errorDescription: "Unable to size the \(preset.rawValue) gesture because the accessibility tree has no application frame. Check an app is in the foreground, or run `offsider doctor --device \(device.rawValue)`.",
                reason: .treeReadFailed
            )
        }
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
