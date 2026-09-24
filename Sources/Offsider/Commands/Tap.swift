import ArgumentParser
import Foundation
import FBControlCore
import FBSimulatorControl
import OffsiderCore

struct Tap: AsyncParsableCommand, VerifiableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Tap a point on the screen, or locate an element by accessibility and tap its activation point."
    )

    @Option(name: .customShort("x"), help: "The X coordinate of the point to tap.")
    var pointX: Double?

    @Option(name: .customShort("y"), help: "The Y coordinate of the point to tap.")
    var pointY: Double?

    @Option(name: [.customLong("id")], help: "Tap the activation point of the element matching AXUniqueId (accessibilityIdentifier). Ignored if -x and -y are provided.")
    var elementID: String?

    @Option(name: [.customLong("label")], help: "Tap the activation point of the element matching AXLabel (accessibilityLabel). Ignored if -x and -y are provided.")
    var elementLabel: String?

    @Option(name: [.customLong("value")], help: "Tap the activation point of the element matching AXValue (the current value of a control). Ignored if -x and -y are provided.")
    var elementValue: String?

    @Option(name: [.customLong("element-type")], help: "Filter matches to elements of this accessibility type (e.g. Button, TextField, Switch). Narrows --id/--label/--value results when multiple elements match.")
    var elementType: String?

    @Option(name: .customLong("pre-delay"), help: "Delay before tapping in seconds.")
    var preDelay: Double?

    @Option(name: .customLong("post-delay"), help: "Delay after tapping in seconds.")
    var postDelay: Double?

    @Option(name: .customLong("tap-style"), help: "Tap event style: automatic uses physical touch for switches/toggles and simulator tap for other targets; simulator always uses FBSimulator tapAt; physical uses touch down/up.")
    var tapStyle: TapStyle?

    @Option(name: .customLong("wait-timeout"), help: "Maximum seconds to poll for the element before failing (0 = no waiting, default). Only applies to --id/--label/--value targeting.")
    var waitTimeout: Double = 0

    @Option(name: .customLong("poll-interval"), help: "Seconds between accessibility tree polls when --wait-timeout is active (default: 0.25).")
    var pollInterval: Double = 0.25

    @OptionGroup
    var verification: VerificationOptions

    @Option(name: .customLong("udid"), help: "The UDID of the simulator.")
    var simulatorUDID: String


    func validate() throws {
        if pointX != nil || pointY != nil {
            guard let pointX, let pointY else {
                throw ValidationError("Both -x and -y must be provided together.")
            }
            guard pointX >= 0, pointY >= 0 else {
                throw ValidationError("Coordinates must be non-negative values.")
            }
        } else {
            let selectorCount = [elementID != nil, elementLabel != nil, elementValue != nil].filter { $0 }.count
            if selectorCount == 0 {
                throw ValidationError("Either provide both -x/-y, or use --id/--label/--value to tap an element.")
            }
            if selectorCount > 1 {
                throw ValidationError("Use only one of --id, --label, or --value.")
            }
            if let elementID, elementID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw ValidationError("--id must not be empty.")
            }
            if let elementLabel, elementLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw ValidationError("--label must not be empty.")
            }
            if let elementValue, elementValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw ValidationError("--value must not be empty.")
            }
        }


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

        guard waitTimeout >= 0 else {
            throw ValidationError("--wait-timeout must be non-negative.")
        }

        if waitTimeout > 0 {
            guard pollInterval > 0 else {
                throw ValidationError("--poll-interval must be greater than 0 when --wait-timeout is active.")
            }
        }
    }

    func run() async throws {
        guard verification.verify else {
            try await execute(progress: nil)
            return
        }
        try await VerifyOutput.reportingFailures(command: "tap", target: verifyTarget, options: verification) { progress in
            try await execute(progress: progress)
        }
    }

    private var verifyTarget: String {
        if let pointX, let pointY { return VerifyOutput.pointDescription(x: pointX, y: pointY) }
        if let elementID { return "id=\(elementID)" }
        if let elementLabel { return "label=\(elementLabel)" }
        return "value=\(elementValue ?? "")"
    }

    private func execute(progress: VerifyProgress?) async throws {
        let logger = OffsiderLogger()
        try await setup(logger: logger)

        try await performGlobalSetup(logger: logger)

        let resolution: TapResolution
        let resolvedDescription: String

        if let pointX, let pointY {
            resolution = TapResolution(point: (x: pointX, y: pointY), isSwitchLikeControl: false)
            resolvedDescription = "(\(pointX), \(pointY))"
        } else {
            let query: AccessibilityQuery
            if let elementID {
                query = .id(elementID)
            } else if let elementLabel {
                query = .label(elementLabel)
            } else if let elementValue {
                query = .value(elementValue)
            } else {
                throw CLIError(errorDescription: "Unexpected state: no coordinates and no element query.")
            }

            do {
                resolution = try await AccessibilityPoller.resolveWithPolling(
                    query: query,
                    simulatorUDID: simulatorUDID,
                    waitTimeout: waitTimeout,
                    pollInterval: pollInterval,
                    elementType: elementType,
                    logger: logger
                )
            } catch let error as ElementResolutionError {
                print("Warning: \(error.localizedDescription) No tap performed.", to: &standardError)
                throw error
            }

            resolvedDescription = "resolved tap point at (\(resolution.point.x), \(resolution.point.y))"
        }

        logger.info().log("Tapping at \(resolvedDescription)")

        let physicalPoint = try await OrientationAwareCoordinates.translate(
            point: resolution.point,
            for: simulatorUDID,
            logger: logger
        )

        let style = resolvedTapStyle(for: resolution)
        if let progress {
            let initial: TapDeliveryStyle = style == .physical ? .physical : .simulator
            let subject = pointX != nil ? "Tap at \(verifyTarget)" : "Tap on \(verifyTarget)"
            let request = VerifyRequest(
                command: "tap",
                subject: subject,
                target: verifyTarget,
                simulatorUDID: simulatorUDID,
                options: verification,
                styles: RetryPolicy.tapStyles(initial: initial, retries: verification.resolvedRetries)
            )
            try await VerifyOutput.perform(request, progress: progress, logger: logger) { attempt, session in
                let attemptStyle: TapStyle = attempt.style == .physical ? .physical : .simulator
                try await dispatchTap(point: physicalPoint, style: attemptStyle, in: session, logger: logger)
            }
            return
        }

        let session = try await HIDInteractor.makeSession(for: simulatorUDID, logger: logger)
        do {
            try await dispatchTap(point: physicalPoint, style: style, in: session, logger: logger)
        } catch {
            await HIDInteractor.closeSession(session)
            throw error
        }
        await HIDInteractor.closeSession(session)

        logger.info().log("Tap completed successfully")
        print("✓ Tap at \(resolvedDescription) completed successfully")
    }

    private func dispatchTap(
        point: (x: Double, y: Double),
        style: TapStyle,
        in session: HIDInteractor.Session,
        logger: OffsiderLogger
    ) async throws {
        switch style {
        case .physical:
            try await HIDInteractor.performPhysicalTap(
                at: point,
                preDelay: preDelay,
                postDelay: postDelay,
                in: session,
                logger: logger
            )
        case .simulator:
            var events: [FBSimulatorHIDEvent] = []
            if let preDelay, preDelay > 0 {
                logger.info().log("Pre-delay: \(preDelay)s")
                events.append(.delay(preDelay))
            }
            events.append(.tapAt(x: point.x, y: point.y))
            if let postDelay, postDelay > 0 {
                logger.info().log("Post-delay: \(postDelay)s")
                events.append(.delay(postDelay))
            }

            let finalEvent = events.count == 1 ? events[0] : FBSimulatorHIDEvent.composite(events)
            try await HIDInteractor.performHIDEvent(finalEvent, in: session, logger: logger)
        case .automatic:
            throw CLIError(errorDescription: "Unexpected tap style resolution.")
        }
    }

    private func resolvedTapStyle(for resolution: TapResolution) -> TapStyle {
        switch tapStyle ?? .automatic {
        case .automatic:
            return resolution.isSwitchLikeControl ? .physical : .simulator
        case .simulator:
            return .simulator
        case .physical:
            return .physical
        }
    }
}
