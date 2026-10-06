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

    @Option(name: .customLong("nth"), help: ArgumentHelp("With several on-screen matches, tap the nth in tree order (1-based) instead of failing as ambiguous.", valueName: "n"))
    var nth: Int?

    @Flag(name: .customLong("topmost"), help: "With several on-screen matches, tap the one drawn on top: the last in tree order on Android, the one a hit-test at its point reaches on iOS.")
    var topmost: Bool = false

    @Flag(name: .customLong("no-settle"), help: "Tap a selector's target at once, without waiting out a transition an input under 500 ms ago may have started.")
    var noSettle: Bool = false

    @OptionGroup
    var verification: VerificationOptions

    @OptionGroup
    var deviceOption: DeviceOption

    @OptionGroup
    var appOption: AppOption


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

        if nth != nil || topmost {
            guard query != nil, pointX == nil else {
                throw ValidationError("--nth and --topmost choose among selector matches; use them with --id, --label or --value.")
            }
            guard nth == nil || !topmost else {
                throw ValidationError("Use only one of --nth or --topmost.")
            }
            if let nth, nth < 1 {
                throw ValidationError("--nth must be 1 or more; got \(nth).")
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
        let route = try await DeviceRouter.routeForInput(deviceOption, logger: logger)
        try await execute(on: route, progress: progress, logger: logger)
    }

    /// Resolves and sends the tap on `route`; tests pass a fake backend here.
    func execute(on route: DeviceRouter.Route, progress: VerifyProgress?, logger: OffsiderLogger) async throws {
        await appOption.apply(to: route)
        let backend = route.backend
        let device = route.device
        try await backend.prepare()

        let resolution: TapResolution
        let resolvedDescription: String
        let resolvedTree: UITree?
        let picker = query.flatMap { matchPicker(query: $0, backend: backend, device: device) }

        if let pointX, let pointY {
            resolution = TapResolution(point: (x: pointX, y: pointY), isSwitchLikeControl: false)
            resolvedDescription = VerifyOutput.pointDescription(x: pointX, y: pointY)
            resolvedTree = nil
            await Self.warnIfOffScreen(x: pointX, y: pointY, backend: backend, device: device)
        } else {
            guard let query else {
                throw CLIError(errorDescription: "Unexpected state: no coordinates and no element query.", reason: .internalError)
            }

            // Under --verify the verifier's second read re-resolves the target, so the guard would only add a read; --verify-id has no such read.
            let settle: SettlePolicy = noSettle || (progress != nil && Self.verifierRereads(verification.mode))
                ? .off
                : .guarded(record: await TreeCache.load(for: device, backend: backend))
            let polled = try await AccessibilityPoller.resolveWithPolling(
                query: query,
                on: backend,
                device: device,
                waitTimeout: resolvedWaitTimeout,
                pollInterval: resolvedPollInterval,
                transientGrace: progress == nil ? 0 : verification.resolvedTimeout,
                elementType: elementType,
                allowOffscreen: allowOffscreen,
                settle: settle,
                pick: picker,
                logger: logger
            )
            resolution = polled.value
            resolvedTree = polled.tree
            Self.warnIfOffScreen(subject: query.selectorDescription, at: resolution.point, in: polled.tree)
            try await checkCover(resolution, selector: query.selectorDescription, tree: polled.tree, backend: backend, device: device)

            resolvedDescription = "\(verifyTarget) at \(VerifyOutput.pointDescription(x: resolution.point.x, y: resolution.point.y))"
        }

        logger.info().log("Tapping \(resolvedDescription)")

        var physicalPoint = try await backend.deviceCoordinates(for: [resolution.point], tree: resolvedTree, on: device)[0]

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
                styles: RetryPolicy.tapStyles(initial: initial, retries: verification.resolvedRetries),
                initialTree: resolvedTree,
                beforeAction: { tree in
                    let pick: MatchPick? = await picker?(tree.roots) ?? nil
                    guard let query, let moved = try? AccessibilityTargetResolver.resolveTap(
                        roots: tree.roots, query: query, elementType: elementType, allowOffscreen: allowOffscreen, explainFailures: false, pick: pick
                    ), abs(moved.point.x - resolution.point.x) > TransitionGuard.frameTolerance
                        || abs(moved.point.y - resolution.point.y) > TransitionGuard.frameTolerance else { return }
                    logger.info().log("\(verifyTarget) moved to \(VerifyOutput.pointDescription(x: moved.point.x, y: moved.point.y)) while settling; tapping there")
                    physicalPoint = try await backend.deviceCoordinates(for: [moved.point], tree: tree, on: device)[0]
                }
            )
            try await VerifyOutput.perform(request, progress: progress) { attempt, session in
                let attemptStyle: TapStyle = attempt.style == .physical ? .physical : .simulator
                try await dispatchTap(point: physicalPoint, style: attemptStyle, in: session, logger: logger)
            }
            return
        }

        let session = try await backend.openTrackedSession(for: device)
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

    /// Only the change check reads the tree again before the input; `--verify-id` acts on the tree the selector resolved on.
    static func verifierRereads(_ mode: Verifier.Mode) -> Bool {
        if case .change = mode { return true }
        return false
    }

    /// `--nth` as given; `--topmost` the last match on Android, and on iOS the one `topmostPick` finds on each tree read.
    func matchPicker(query: AccessibilityQuery, backend: any DeviceBackend, device: DeviceID) -> MatchPicker? {
        if let nth { return { _ in .nth(nth) } }
        guard topmost else { return nil }
        guard device.platform == .ios else { return { _ in .last } }
        let elementType = elementType
        let allowOffscreen = allowOffscreen
        return { roots in
            await Self.topmostPick(roots: roots, query: query, elementType: elementType, allowOffscreen: allowOffscreen) { point in
                (try? await backend.accessibilityTree(for: device, point: point))?.roots.first
            }
        }
    }

    /// The first match whose own point hit-tests back to it, else the last; a single match needs no hit-test.
    static func topmostPick(
        roots: [UINode],
        query: AccessibilityQuery,
        elementType: String?,
        allowOffscreen: Bool,
        hitTest: (UIPoint) async -> UINode?
    ) async -> MatchPick {
        let found = AccessibilityTargetResolver.candidates(roots: roots, query: query, elementType: elementType)
        guard found.matches.count > 1 else { return .last }
        let pool = allowOffscreen ? found.matches : found.onScreen
        for index in pool.indices {
            guard let resolution = try? AccessibilityTargetResolver.resolveTap(
                roots: roots, query: query, elementType: elementType, allowOffscreen: allowOffscreen, explainFailures: false, pick: .nth(index + 1)
            ), let matched = resolution.matched else { continue }
            if let hit = await hitTest(UIPoint(x: resolution.point.x, y: resolution.point.y)),
               AccessibilityTargetResolver.isFamily(hit, of: matched, in: roots) {
                return .nth(index + 1)
            }
        }
        return .last
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
        let message = Self.coverMessage(selector: selector, at: resolution.point, cover: cover, roots: tree.roots)
        if failIfCovered {
            let underKeyboard = AccessibilityTargetResolver.isUnderKeyboard(cover, in: tree.roots)
            throw CLIError(
                errorDescription: message,
                reason: underKeyboard ? .targetUnderKeyboard : .targetCovered,
                hint: "offsider describe-ui --device \(device.rawValue) --summary"
            )
        }
        print("Warning: \(message) Pass --fail-if-covered to stop instead.", to: &standardError)
    }

    /// iOS asks the accessibility service what is at the point; Android's point read only walks tree order, which is not z-order.
    private static func hitTest(at point: (x: Double, y: Double), backend: any DeviceBackend, device: DeviceID) async -> UINode? {
        (try? await backend.accessibilityTree(for: device, point: UIPoint(x: point.x, y: point.y)))?.roots.first
    }

    /// `--id 'save' at (196, 700) may be covered by button 'Dismiss' (20, 650) 350x120; the tap may land on it.`
    /// A key of the on-screen keyboard reads `the keyboard (key 'v')`, since the key itself means little.
    static func coverMessage(selector: String, at point: (x: Double, y: Double), cover: UINode, roots: [UINode] = []) -> String {
        let pointText = VerifyOutput.pointDescription(x: point.x, y: point.y)
        if AccessibilityTargetResolver.isUnderKeyboard(cover, in: roots) {
            let key = (cover.normalizedLabel ?? cover.normalizedID).map { " (key '\(SelectorText.truncated($0))')" } ?? ""
            return "\(selector) at \(pointText) may be covered by the keyboard\(key); the tap may land on it."
        }
        var parts = [cover.role.rawValue]
        if let name = cover.normalizedLabel ?? cover.normalizedID {
            parts.append("'\(SelectorText.truncated(name))'")
        }
        if let frame = cover.frame {
            parts.append(frame.summary)
        }
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
            throw CLIError(errorDescription: "Unexpected tap style resolution.", reason: .internalError)
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
