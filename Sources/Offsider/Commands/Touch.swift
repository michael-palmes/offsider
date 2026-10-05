import ArgumentParser
import Foundation
import OffsiderCore

struct Touch: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Perform precise touch down/up events at specific coordinates.",
        discussion: """
        Perform low-level touch events for advanced gesture control.
        You can either perform a single touch down, touch up, or both.
        
        Examples:
          offsider touch --x 100 --y 200 --down --device DEVICE_ID        # Touch down at (100, 200)
          offsider touch --x 100 --y 200 --up --device DEVICE_ID          # Touch up at (100, 200)
          offsider touch --x 100 --y 200 --down --up --device DEVICE_ID   # Touch down then up (like tap)
          offsider touch --x 100 --y 200 --down --up --delay 1.0 --device DEVICE_ID # Long press (hold for 1s)
          offsider touch -x 200 -y 400 --fingers 2 --hold 1000 --device DEVICE_ID # Two fingers held for 1s

        With --fingers 2, -x and -y are the centre and the fingers sit --spread points apart on a horizontal line; \
        both go down together, stay down for --hold milliseconds and lift together. An iOS simulator's main display \
        and Android emulators (gRPC or the UiAutomation helper) take two fingers; a physical iPhone and the iPhone \
        Duo's inner display refuse them.
        """
    )
    
    @Option(name: .customShort("x"), help: "The X coordinate of the touch point.")
    var pointX: Double
    
    @Option(name: .customShort("y"), help: "The Y coordinate of the touch point.")
    var pointY: Double
    
    @Flag(name: .customLong("down"), help: "Perform touch down event.")
    var touchDown: Bool = false
    
    @Flag(name: .customLong("up"), help: "Perform touch up event.")
    var touchUp: Bool = false
    
    @Option(name: .customLong("delay"), help: "Delay between touch down and up events in seconds (if both are specified).")
    var delay: Double?
    
    @Option(help: ArgumentHelp("Fingers to touch with, 1 or 2; 2 needs --hold.", valueName: "n"))
    var fingers: Int = 1

    @Option(help: ArgumentHelp("With --fingers 2: milliseconds both fingers stay down, from 100 to 10000.", valueName: "ms"))
    var hold: Int?

    @Option(help: ArgumentHelp("With --fingers 2: points between the fingers, from 20 to 300.", valueName: "points"))
    var spread: Double?

    @OptionGroup
    var deviceOption: DeviceOption

    static let defaultSpread: Double = 60
    static let holdRange = 100...10_000
    static let spreadRange: ClosedRange<Double> = 20...300

    func validate() throws {
        // Validate coordinates are non-negative
        guard pointX >= 0, pointY >= 0 else {
            throw ValidationError("Coordinates must be non-negative values.")
        }
        guard fingers == 1 || fingers == 2 else {
            throw ValidationError("--fingers must be 1 or 2; got \(fingers).")
        }
        if fingers == 2 {
            try validateTwoFingers()
            return
        }
        if hold != nil {
            throw ValidationError("--hold needs --fingers 2. For one finger, hold with --down --up --delay <seconds>.")
        }
        if spread != nil {
            throw ValidationError("--spread needs --fingers 2.")
        }
        
        // Validate that at least one action is specified
        guard touchDown || touchUp else {
            throw ValidationError("At least one of --down or --up must be specified.")
        }
        
        // Validate delay if provided
        if let delay = delay {
            guard delay >= 0 else {
                throw ValidationError("Delay must be non-negative.")
            }
            guard delay <= 10.0 else {
                throw ValidationError("Delay must not exceed 10 seconds.")
            }
            
            // Delay only makes sense if both down and up are specified
            guard touchDown && touchUp else {
                throw ValidationError("Delay can only be used when both --down and --up are specified.")
            }
        }
    }

    private func validateTwoFingers() throws {
        if touchDown || touchUp || delay != nil {
            throw ValidationError("--fingers 2 presses and lifts both fingers itself; drop --down, --up and --delay and set the hold with --hold <ms>.")
        }
        guard let hold else {
            throw ValidationError("--fingers 2 needs --hold <ms>, from 100 to 10000.")
        }
        guard Self.holdRange.contains(hold) else {
            throw ValidationError("--hold must be from 100 to 10000 milliseconds; got \(hold).")
        }
        if let spread, !Self.spreadRange.contains(spread) {
            throw ValidationError("--spread must be from 20 to 300 points; got \(spread.formatted()).")
        }
    }

    /// The two fingers, left then right of the centre; a finger off the screen is a usage error naming it.
    static func fingerPoints(x: Double, y: Double, spread: Double, screen: UISize?) throws -> [(x: Double, y: Double)] {
        let points = [(x: x - spread / 2, y: y), (x: x + spread / 2, y: y)]
        for (index, point) in points.enumerated() {
            let inside = point.x >= 0 && point.y >= 0 && screen.map { point.x <= $0.width && point.y <= $0.height } ?? true
            guard inside else {
                let size = screen.map { " on a \($0.width.formatted()) x \($0.height.formatted()) screen" } ?? ""
                throw CLIError(
                    errorDescription: "Finger \(index + 1) at (\(point.x.formatted()), \(point.y.formatted())) is off the screen\(size). Move -x or lower --spread.",
                    reason: .usage
                )
            }
        }
        return points
    }

    /// Both fingers down, held, then up, as one event the backend sends in one go.
    func twoFingerEvent(backend: any DeviceBackend, device: DeviceID) async throws -> InputEvent {
        let points = try Self.fingerPoints(x: pointX, y: pointY, spread: spread ?? Self.defaultSpread, screen: try await backend.screenSize(for: device))
        let physical = try await backend.deviceCoordinates(for: points, tree: nil, on: device)
        let (first, second) = (physical[0], physical[1])
        return .composite([
            .twoFingerTouch(direction: .down, x1: first.x, y1: first.y, x2: second.x, y2: second.y),
            .delay(Double(hold ?? 0) / 1000),
            .twoFingerTouch(direction: .up, x1: first.x, y1: first.y, x2: second.x, y2: second.y),
        ])
    }

    func run() async throws {
        let logger = OffsiderLogger()
        let route = try await DeviceRouter.routeForInput(deviceOption, logger: logger)
        let backend = route.backend
        let device = route.device
        try await backend.prepare()

        if fingers == 2 {
            logger.info().log("Two-finger touch at (\(pointX), \(pointY)) for \(hold ?? 0) ms")
            try await backend.performTracked(try await twoFingerEvent(backend: backend, device: device), on: device)
            return
        }

        logger.info().log("Performing touch events at (\(pointX), \(pointY))")

        let physicalPoint = try await backend.deviceCoordinates(for: [(x: pointX, y: pointY)], tree: nil, on: device)[0]

        var steps: [DetachedTouchStep] = []
        if touchDown && touchUp {
            // Send down and up as separate HID submissions so iOS recognizers
            // observe a real hold duration for long-press gestures.
            let touchDelay = delay ?? TapTiming.defaultHoldDuration

            logger.info().log("Touch down")
            steps.append(.down(x: physicalPoint.x, y: physicalPoint.y))

            if touchDelay > 0 {
                logger.info().log("Delay: \(touchDelay) seconds")
                steps.append(.hold(touchDelay))
            }

            logger.info().log("Touch up")
            steps.append(.up(x: physicalPoint.x, y: physicalPoint.y))
        } else if touchDown {
            logger.info().log("Touch down")
            steps.append(.down(x: physicalPoint.x, y: physicalPoint.y))
        } else {
            logger.info().log("Touch up")
            steps.append(.up(x: physicalPoint.x, y: physicalPoint.y))
        }

        do {
            try await backend.sendDetachedTouch(steps, to: device)
        } catch {
            await DeviceActivityLedger.current.recordInput(on: device)
            throw error
        }
        await DeviceActivityLedger.current.recordInput(on: device)
        
        logger.info().log("Touch events completed successfully")
    }
} 
