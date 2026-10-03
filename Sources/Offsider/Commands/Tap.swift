import ArgumentParser
import Foundation
import OffsiderCore

struct Tap: AsyncParsableCommand, VerifiableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Tap a point on the screen, or locate an element by accessibility and tap its activation point."
    )

    @Option(name: .customShort("x"), help: "The X coordinate of the point to tap.")
    var pointX: Double?

    @Option(name: .customShort("y"), help: "The Y coordinate of the point to tap.")
    var pointY: Double?

    @Option(name: [.customLong("id")], help: "Tap the activation point of the element whose describe-ui id matches (accessibilityIdentifier, or testID in React Native). Ignored if -x and -y are provided.")
    var elementID: String?

    @Option(name: [.customLong("label")], help: "Tap the activation point of the element whose describe-ui label matches (accessibilityLabel). Ignored if -x and -y are provided.")
    var elementLabel: String?

    @Option(name: [.customLong("value")], help: "Tap the activation point of the element whose describe-ui value matches (the current value of a control). Ignored if -x and -y are provided.")
    var elementValue: String?

    @Option(name: [.customLong("element-type")], help: "Filter matches to this describe-ui role in any case (e.g. button, textField, switch) or exact native type (e.g. TextEditor). Narrows --id/--label/--value results when multiple elements match.")
    var elementType: String?

    @Option(name: .customLong("pre-delay"), help: "Delay before tapping in seconds.")
    var preDelay: Double?

    @Option(name: .customLong("post-delay"), help: "Delay after tapping in seconds.")
    var postDelay: Double?

    @Option(name: .customLong("tap-style"), help: "Tap event style: automatic uses physical touch for switches and a single tap event for other targets; simulator always sends a single tap event; physical uses touch down and up.")
    var tapStyle: TapStyle?

    @Option(name: .customLong("wait-timeout"), help: "Maximum seconds to poll for the element before failing (0 = no waiting, default). Only applies to --id/--label/--value targeting.")
    var waitTimeout: Double?

    @Option(name: .customLong("poll-interval"), help: "Seconds between accessibility tree polls when --wait-timeout is active (default: 0.25).")
    var pollInterval: Double?

    @Flag(name: .customLong("allow-offscreen"), help: "Resolve elements whose frame is outside the screen (off by default: selectors prefer on-screen matches).")
    var allowOffscreen: Bool = false

    @Flag(name: .customLong("fail-if-covered"), help: "Fail instead of warning when another element may cover the tap point.")
    var failIfCovered: Bool = false

    @OptionGroup
    var verification: VerificationOptions

    @OptionGroup
    var deviceOption: DeviceOption


    func validate() throws {
        if pointX != nil || pointY != nil {
            guard let pointX, let pointY else {
                throw ValidationError("Both -x and -y must be provided together.")
            }
            guard pointX >= 0, pointY >= 0 else {
                throw ValidationError("Coordinates must be non-negative values.")
            }
        } else {
            try SelectorQuery.validate(id: elementID, label: elementLabel, value: elementValue)
            if query == nil {
                throw ValidationError("Either provide both -x/-y, or use --id/--label/--value to tap an element.")
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

        guard resolvedWaitTimeout >= 0 else {
            throw ValidationError("--wait-timeout must be non-negative.")
        }

        if resolvedWaitTimeout > 0 {
            guard resolvedPollInterval > 0 else {
                throw ValidationError("--poll-interval must be greater than 0 when --wait-timeout is active.")
            }
        }
    }

    /// Optional so a batch step can tell an explicit value from the batch-level default.
    var resolvedWaitTimeout: Double { waitTimeout ?? 0 }
    var resolvedPollInterval: Double { pollInterval ?? 0.25 }

    private var query: AccessibilityQuery? {
        SelectorQuery.make(id: elementID, label: elementLabel, value: elementValue)
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
        let route = try await DeviceRouter.route(deviceOption.id, logger: logger)
        try await execute(on: route, progress: progress, logger: logger)
    }

    /// Resolves and sends the tap on `route`; tests pass a fake backend here.
    func execute(on route: DeviceRouter.Route, progress: VerifyProgress?, logger: OffsiderLogger) async throws {
        let backend = route.backend
        let device = route.device
        try await backend.prepare()

        let resolution: TapResolution
        let resolvedDescription: String
        let resolvedTree: UITree?

        if let pointX, let pointY {
            resolution = TapResolution(point: (x: pointX, y: pointY), isSwitchLikeControl: false)
            resolvedDescription = VerifyOutput.pointDescription(x: pointX, y: pointY)
            resolvedTree = nil
            await Self.warnIfOffScreen(x: pointX, y: pointY, backend: backend, device: device)
        } else {
            guard let query else {
                throw CLIError(errorDescription: "Unexpected state: no coordinates and no element query.")
            }

            let polled = try await AccessibilityPoller.resolveWithPolling(
                query: query,
                on: backend,
                device: device,
                waitTimeout: resolvedWaitTimeout,
                pollInterval: resolvedPollInterval,
                transientGrace: progress == nil ? 0 : verification.resolvedTimeout,
                elementType: elementType,
                allowOffscreen: allowOffscreen,
                logger: logger
            )
            resolution = polled.value
            resolvedTree = polled.tree
            Self.warnIfOffScreen(subject: query.selectorDescription, at: resolution.point, in: polled.tree)
            try await checkCover(resolution, selector: query.selectorDescription, tree: polled.tree, backend: backend, device: device)

            resolvedDescription = "\(verifyTarget) at \(VerifyOutput.pointDescription(x: resolution.point.x, y: resolution.point.y))"
        }

        logger.info().log("Tapping \(resolvedDescription)")

        let physicalPoint = try await backend.deviceCoordinates(for: [resolution.point], tree: resolvedTree, on: device)[0]

        let style = resolvedTapStyle(for: resolution)
        if let progress {
            let initial: TapDeliveryStyle = style == .physical ? .physical : .simulator
            let subject = pointX != nil ? "Tap at \(verifyTarget)" : "Tap on \(verifyTarget)"
            let request = VerifyRequest(
                command: "tap",
                subject: subject,
                target: verifyTarget,
                backend: backend,
                device: device,
                options: verification,
                styles: RetryPolicy.tapStyles(initial: initial, retries: verification.resolvedRetries)
            )
            try await VerifyOutput.perform(request, progress: progress) { attempt, session in
                let attemptStyle: TapStyle = attempt.style == .physical ? .physical : .simulator
                try await dispatchTap(point: physicalPoint, style: attemptStyle, in: session, logger: logger)
            }
            return
        }

        let session = try await backend.openInputSession(for: device)
        do {
            try await dispatchTap(point: physicalPoint, style: style, in: session, logger: logger)
        } catch {
            await session.close()
            throw error
        }
        await session.close()

        logger.info().log("Tap completed successfully")
        print(Self.completionLine(selector: pointX == nil ? verifyTarget : nil, at: resolution.point))
    }

    /// Warns rather than refuses, since an iPad app in a window can be smaller than the screen.
    @MainActor
    static func warnIfOffScreen(x: Double, y: Double, backend: any DeviceBackend, device: DeviceID) async {
        if let warning = offScreenWarning(x: x, y: y, screen: try? await backend.screenSize(for: device)) {
            print(warning, to: &standardError)
        }
    }

    static func offScreenWarning(x: Double, y: Double, screen: UISize?) -> String? {
        guard let screen, screen.width > 0, screen.height > 0 else {
            return nil
        }
        let bounds = UIFrame(x: 0, y: 0, width: screen.width, height: screen.height)
        guard !bounds.contains(UIPoint(x: x, y: y)) else {
            return nil
        }
        return "Warning: \(VerifyOutput.pointDescription(x: x, y: y)) is outside the \(bounds.sizeSummary) screen; the tap may do nothing."
    }

    /// Warns when a selector's point is outside the screen, which only `--allow-offscreen` lets through.
    static func warnIfOffScreen(subject: String, at point: (x: Double, y: Double), in tree: UITree) {
        guard let viewport = tree.viewport, !viewport.contains(UIPoint(x: point.x, y: point.y)) else {
            return
        }
        let pointText = VerifyOutput.pointDescription(x: point.x, y: point.y)
        print("Warning: \(subject) at \(pointText) is outside the \(viewport.sizeSummary) screen; the tap may do nothing.", to: &standardError)
    }

    /// Confirms a cover candidate with one hit-test at the tap point, then warns on stderr or, with `--fail-if-covered`, throws.
    func checkCover(
        _ resolution: TapResolution,
        selector: String,
        tree: UITree,
        backend: any DeviceBackend,
        device: DeviceID
    ) async throws {
        guard !resolution.coverCandidates.isEmpty else {
            return
        }
        let hit = tree.platform == .ios ? await Self.hitTest(at: resolution.point, backend: backend, device: device) : nil
        guard let cover = AccessibilityTargetResolver.confirmedCover(hit: hit, resolution: resolution, roots: tree.roots) else {
            return
        }
        let message = Self.coverMessage(selector: selector, at: resolution.point, cover: cover)
        if failIfCovered {
            throw CLIError(errorDescription: message)
        }
        print("Warning: \(message) Pass --fail-if-covered to stop instead.", to: &standardError)
    }

    /// iOS asks the accessibility service what is at the point; Android's point read only walks tree order, which is not z-order.
    private static func hitTest(at point: (x: Double, y: Double), backend: any DeviceBackend, device: DeviceID) async -> UINode? {
        (try? await backend.accessibilityTree(for: device, point: UIPoint(x: point.x, y: point.y)))?.roots.first
    }

    /// `--id 'save' at (196, 700) may be covered by button 'Dismiss' (20, 650) 350x120; the tap may land on it.`
    static func coverMessage(selector: String, at point: (x: Double, y: Double), cover: UINode) -> String {
        var parts = [cover.role.rawValue]
        if let name = cover.normalizedLabel ?? cover.normalizedID {
            parts.append("'\(SelectorText.truncated(name))'")
        }
        if let frame = cover.frame {
            parts.append(frame.summary)
        }
        let pointText = VerifyOutput.pointDescription(x: point.x, y: point.y)
        return "\(selector) at \(pointText) may be covered by \(parts.joined(separator: " ")); the tap may land on it."
    }

    /// `✓ Tap at (x, y) ...` for coordinates; `✓ Tap on id=X at (x, y) ...` for a selector.
    static func completionLine(selector: String?, at point: (x: Double, y: Double)) -> String {
        let pointText = VerifyOutput.pointDescription(x: point.x, y: point.y)
        guard let selector else {
            return "✓ Tap at \(pointText) completed successfully"
        }
        return "✓ Tap on \(selector) at \(pointText) completed successfully"
    }

    private func dispatchTap(
        point: (x: Double, y: Double),
        style: TapStyle,
        in session: any InputSession,
        logger: OffsiderLogger
    ) async throws {
        switch style {
        case .physical:
            try await session.performPhysicalTap(at: point, preDelay: preDelay, postDelay: postDelay)
        case .simulator:
            if let preDelay, preDelay > 0 {
                logger.info().log("Pre-delay: \(preDelay)s")
            }
            if let postDelay, postDelay > 0 {
                logger.info().log("Post-delay: \(postDelay)s")
            }

            let finalEvent = InputEvent.delayed(.tapAt(x: point.x, y: point.y), pre: preDelay, post: postDelay)
            try await session.perform(finalEvent)
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
