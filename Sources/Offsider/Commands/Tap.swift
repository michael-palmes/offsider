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

    @Option(name: [.customLong("label")], help: "Tap the activation point of the element whose describe-ui label matches (accessibilityLabel); with --id, the element must match both. Ignored if -x and -y are provided.")
    var elementLabel: String?

    @Option(name: [.customLong("label-contains")], help: ArgumentHelp("Like --label, for the element whose describe-ui label holds this text, in the same case, such as one part of a label React Native merged.", valueName: "text"))
    var elementLabelContains: String?

    @Option(name: [.customLong("value")], help: "Tap the activation point of the element whose describe-ui value matches (the current value of a control); with --id, the element must match both. Ignored if -x and -y are provided.")
    var elementValue: String?

    @Option(name: [.customLong("element-type")], help: "Filter matches to this describe-ui role in any case (e.g. button, textField, switch) or exact native type (e.g. TextEditor). Narrows --id/--label/--label-contains/--value results when multiple elements match.")
    var elementType: String?

    @Option(name: .customLong("pre-delay"), help: "Delay before tapping in seconds.")
    var preDelay: Double?

    @Option(name: .customLong("post-delay"), help: "Delay after tapping in seconds.")
    var postDelay: Double?

    @Option(name: .customLong("tap-style"), help: "Tap event style: automatic uses physical touch for switches and a single tap event for other targets; simulator always sends a single tap event; physical uses touch down and up.")
    var tapStyle: TapStyle?

    @Option(name: .customLong("wait-timeout"), help: "Maximum seconds to poll for the element before failing (0 = no waiting, default). Only applies to --id/--label/--label-contains/--value targeting.")
    var waitTimeout: Double?

    @Option(name: .customLong("poll-interval"), help: "Seconds between accessibility tree polls when --wait-timeout is active (default: 0.25).")
    var pollInterval: Double?

    @Flag(name: .customLong("allow-offscreen"), help: "Resolve elements whose frame is outside the screen (off by default: selectors prefer on-screen matches).")
    var allowOffscreen: Bool = false

    @Flag(name: .customLong("fail-if-covered"), help: "Also refuse when another element may cover the target by tree order alone, a guess that otherwise only warns. Hit-tests the point on an iOS simulator, and on Android reads the target's text in a screenshot when only an empty view is in doubt. A cover a hit-test or Android's drawing order finds refuses without it, and the keyboard always does.")
    var failIfCovered: Bool = false

    @Flag(name: .customLong("allow-covered"), help: "Tap even when a hit-test or Android's drawing order finds another element over the target, with a warning; the keyboard still refuses.")
    var allowCovered: Bool = false

    @Flag(name: .customLong("allow-disabled"), help: "Tap a selector's target even when it says it is disabled, with a warning, to prove a disabled control does nothing; without it such a tap is refused and nothing is sent.")
    var allowDisabled: Bool = false

    @Option(name: .customLong("nth"), help: ArgumentHelp("With several on-screen matches, tap the nth in tree order (1-based) instead of failing as ambiguous.", valueName: "n"))
    var nth: Int?

    @Flag(name: .customLong("topmost"), help: "With several on-screen matches, tap the one drawn on top: the only one on the front page when a page is drawn over the others, else the one a hit-test at its point reaches on an iOS simulator, else the one the tree draws on top there (Android drawing order, or tree order).")
    var topmost: Bool = false

    @Flag(name: .customLong("no-settle"), help: "Tap a selector's target at once, without waiting out a transition an input under 500 ms ago may have started.")
    var noSettle: Bool = false

    @Flag(name: .customLong("dry-run"), help: "Find the target and check what a touch there would reach, then stop: nothing is sent. Takes a selector; exits as the tap would.")
    var dryRun: Bool = false

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
            if let problem = Coordinates.problem([("-x", pointX), ("-y", pointY)]) {
                throw ValidationError(problem)
            }
            guard pointX >= 0, pointY >= 0 else {
                throw ValidationError("Coordinates must be non-negative values.")
            }
        } else {
            try SelectorQuery.validate(id: elementID, label: elementLabel, labelContains: elementLabelContains, value: elementValue, refining: true)
            if query == nil {
                throw ValidationError("Either provide both -x/-y, or use --id/--label/--label-contains/--value to tap an element.")
            }
        }

        if nth != nil || topmost {
            guard query != nil, pointX == nil else {
                throw ValidationError("--nth and --topmost choose among selector matches; use them with --id, --label, --label-contains or --value.")
            }
            guard nth == nil || !topmost else {
                throw ValidationError("Use only one of --nth or --topmost.")
            }
            if let nth, nth < 1 {
                throw ValidationError("--nth must be 1 or more; got \(nth).")
            }
        }

        if allowCovered, failIfCovered {
            throw ValidationError("Use only one of --allow-covered or --fail-if-covered.")
        }

        if dryRun {
            guard pointX == nil else {
                throw ValidationError("--dry-run checks an element; use it with --id, --label, --label-contains or --value.")
            }
            guard !verification.verify else {
                throw ValidationError("--dry-run sends nothing, so there is nothing to verify.")
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

    var query: AccessibilityQuery? {
        SelectorQuery.make(id: elementID, label: elementLabel, labelContains: elementLabelContains, value: elementValue)
    }

    func run() async throws {
        guard verification.verify else {
            try await InputOutput.reporting(command: "tap", target: verifyTarget, json: verification.json) { details in
                try await execute(progress: nil, details: details)
            }
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
        if let elementLabelContains { return "label-contains=\(elementLabelContains)" }
        return "value=\(elementValue ?? "")"
    }

    /// What the spinner says, which never claims a tap a dry run will not send.
    var progressLabel: String { dryRun ? "Checking \(verifyTarget)" : "Tapping \(verifyTarget)" }

    private func execute(progress: VerifyProgress?, details: InputDetails? = nil) async throws {
        let logger = OffsiderLogger()
        let route = try await DeviceRouter.routeForInput(deviceOption, logger: logger)
        try await Console.current.progress(progressLabel) {
            try await execute(on: route, progress: progress, logger: logger, details: details)
        }
    }

    /// Resolves and sends the tap on `route`; tests pass a fake backend here. `details` learns the point it resolved.
    func execute(on route: DeviceRouter.Route, progress: VerifyProgress?, logger: OffsiderLogger, details: InputDetails? = nil) async throws {
        await appOption.apply(to: route)
        let backend = route.backend
        let device = route.device
        try await backend.prepare()

        let resolution: TapResolution
        let resolvedDescription: String
        let resolvedTree: UITree?
        let picker = query.flatMap { matchPicker(query: $0, backend: backend, device: device) }
        let checkCover = coverCheck(query: query, backend: backend, device: device)
        let startedAt = ProcessInfo.processInfo.systemUptime
        var lastInput: Date?

        if let pointX, let pointY {
            resolution = TapResolution(point: (x: pointX, y: pointY), isSwitchLikeControl: false)
            resolvedDescription = VerifyOutput.pointDescription(x: pointX, y: pointY)
            resolvedTree = nil
            await Self.warnIfOffScreen(x: pointX, y: pointY, backend: backend, device: device)
        } else {
            guard let query else {
                throw CLIError(errorDescription: "Unexpected state: no coordinates and no element query.", reason: .internalError)
            }

            let record = noSettle ? nil : await TreeCache.load(for: device, backend: backend)
            lastInput = record?.lastInputAt
            // Under --verify the verifier's second read re-resolves the target, so the guard would only add a read; --verify-id has no such read.
            let settle: SettlePolicy = noSettle || (progress != nil && Self.verifierRereads(verification.mode))
                ? .off
                : .guarded(record: record)
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
                coverCheck: checkCover,
                coverSettle: TapCover.coverSettle(lastInput: lastInput),
                readsHiddenCovers: failIfCovered,
                logger: logger
            )
            resolution = polled.value
            resolvedTree = polled.tree
            Self.warnIfOffScreen(subject: query.selectorDescription, at: resolution.point, in: polled.tree)

            resolvedDescription = "\(verifyTarget) at \(VerifyOutput.pointDescription(x: resolution.point.x, y: resolution.point.y))"
        }

        details?.point = UIPoint(x: resolution.point.x, y: resolution.point.y)
        if dryRun {
            details?.dryRun = true
            Console.current.show(InputPersonView.receipt(
                "Would tap \(verifyTarget)",
                aside: VerifyOutput.pointDescription(x: resolution.point.x, y: resolution.point.y),
                details: ["Nothing was sent"],
                agent: "✓ Dry run: a tap on \(verifyTarget) at \(VerifyOutput.pointDescription(x: resolution.point.x, y: resolution.point.y)) would reach it. Nothing was sent.\n"
            ))
            return
        }
        logger.info().log("Tapping \(resolvedDescription)")

        var physicalPoint = try await backend.deviceCoordinates(for: [resolution.point], tree: resolvedTree, on: device)[0]

        let style = resolvedTapStyle(for: resolution)
        if let progress {
            let initial: TapDeliveryStyle = style == .physical ? .physical : .simulator
            let subject = pointX != nil ? "Tap at \(verifyTarget)" : "Tap on \(verifyTarget)"
            let targetNode = resolution.target ?? resolution.matched
            var aimed = resolution.point
            var aimedFrame = targetNode?.frame
            /// The tap the target's place in `tree` calls for, judged as the first read was, so the check covers the point sent; a target gone or newly covered throws.
            func resolvedAgain(in tree: UITree, waitTimeout: TimeInterval, coverSettle: TimeInterval = 0) async throws -> TapResolution {
                guard let query else { return resolution }
                var first: UITree? = tree
                let watchdog = DeviceWatchdog()
                return try await AccessibilityPoller.pollForResolution(
                    query: query, waitTimeout: waitTimeout, pollInterval: resolvedPollInterval, elementType: elementType, allowOffscreen: allowOffscreen,
                    pick: picker, coverCheck: checkCover, coverSettle: coverSettle, logger: logger
                ) {
                    try await watchdog.guardingInputRead(of: device) {
                        let read: UITree
                        if let held = first {
                            read = held
                            first = nil
                        } else {
                            read = try await backend.accessibilityTree(for: device)
                        }
                        return await AccessibilityPoller.judged(read, query: query, elementType: elementType, allowOffscreen: allowOffscreen, readsHiddenCovers: failIfCovered, pick: picker, backend: backend, device: device)
                    }
                }.value
            }
            func isAimed(_ point: (x: Double, y: Double)) -> Bool {
                abs(point.x - aimed.x) <= TransitionGuard.frameTolerance && abs(point.y - aimed.y) <= TransitionGuard.frameTolerance
            }
            let request = VerifyRequest(
                command: "tap",
                subject: subject,
                target: verifyTarget,
                backend: backend,
                device: device,
                options: verification,
                styles: RetryPolicy.tapStyles(initial: initial, retries: verification.resolvedRetries(target: targetNode)),
                // Verify compares plain reads, and a filled tree can differ from one in shape as well as content.
                initialTree: resolvedTree?.filledFromGaps == nil ? resolvedTree : nil,
                targetNode: targetNode,
                beforeAction: { tree in
                    guard query != nil, Self.verifierRereads(verification.mode) else { return }
                    let elapsed = ProcessInfo.processInfo.systemUptime - startedAt
                    let tap = try await resolvedAgain(in: tree, waitTimeout: max(0, resolvedWaitTimeout - elapsed), coverSettle: TapCover.coverSettle(lastInput: lastInput))
                    guard !isAimed(tap.point) else { return }
                    logger.info().log("\(verifyTarget) moved to \(VerifyOutput.pointDescription(x: tap.point.x, y: tap.point.y)) while settling; tapping there")
                    physicalPoint = try await backend.deviceCoordinates(for: [tap.point], tree: tree, on: device)[0]
                    aimed = tap.point
                    aimedFrame = (tap.target ?? tap.matched)?.frame
                },
                targetStays: query == nil ? nil : { tree in
                    guard let tap = try? await resolvedAgain(in: tree, waitTimeout: 0) else { return false }
                    return isAimed(tap.point)
                },
                expectsDevMenu: { tree in Self.aimsAtDevMenu(targetNode, point: resolution.point, in: tree) },
                keyboardOnlyFails: query != nil && !Self.closesKeyboard(targetNode, in: resolvedTree),
                targetArea: { query == nil ? UIFrame(x: aimed.x, y: aimed.y, width: 0, height: 0) : aimedFrame }
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
        let selector = pointX == nil ? verifyTarget : nil
        Console.current.show(InputPersonView.receipt(
            Self.receiptHeadline(selector: selector, at: resolution.point),
            aside: selector == nil ? nil : VerifyOutput.pointDescription(x: resolution.point.x, y: resolution.point.y),
            agent: Self.completionLine(selector: selector, at: resolution.point) + "\n"
        ))
    }

    /// A keyboard's own control, such as Done or a key, whose one effect may rightly be closing the keyboard.
    static func closesKeyboard(_ target: UINode?, in tree: UITree?) -> Bool {
        guard let target else { return false }
        return KeyboardDismiss.closesKeyboard(target) || tree.map { AccessibilityTargetResolver.isUnderKeyboard(target, in: $0.roots) } == true
    }

    /// True when no floating dev menu button shows, so a tap cannot have reached one by mistake, or the tap names it: `target` holds its icon, or a coordinate tap lands on the icon.
    static func aimsAtDevMenu(_ target: UINode?, point: (x: Double, y: Double), in tree: UITree) -> Bool {
        guard let viewport = tree.viewport else { return true }
        let buttons = KnownOverlays.devMenuButtons(in: tree.roots, viewport: viewport)
        guard !buttons.isEmpty else { return true }
        if let target {
            return buttons.contains { button in target.flattened().contains { $0.isSameElement(as: button) } }
        }
        return buttons.contains { $0.frame?.contains(UIPoint(x: point.x, y: point.y)) == true }
    }

    /// `Tapped id=save` for a selector, `Tapped (120, 640)` for a point; never more than the command line gave.
    static func receiptHeadline(selector: String?, at point: (x: Double, y: Double)) -> String {
        "Tapped " + (selector ?? VerifyOutput.pointDescription(x: point.x, y: point.y))
    }

    /// Warns rather than refuses, since an iPad app in a window can be smaller than the screen.
    @MainActor
    static func warnIfOffScreen(x: Double, y: Double, backend: any DeviceBackend, device: DeviceID) async {
        if let warning = offScreenText(x: x, y: y, screen: try? await backend.screenSize(for: device)) {
            Console.current.notice(.warning(String(warning.dropLast()), agent: warning))
        }
    }

    static func offScreenWarning(x: Double, y: Double, screen: UISize?) -> String? {
        offScreenText(x: x, y: y, screen: screen).map { "Warning: \($0)" }
    }

    private static func offScreenText(x: Double, y: Double, screen: UISize?) -> String? {
        guard let screen, screen.width > 0, screen.height > 0 else {
            return nil
        }
        let bounds = UIFrame(x: 0, y: 0, width: screen.width, height: screen.height)
        guard !bounds.contains(UIPoint(x: x, y: y)) else {
            return nil
        }
        return "\(VerifyOutput.pointDescription(x: x, y: y)) is outside the \(bounds.sizeSummary) screen; the tap may do nothing."
    }

    /// Only the change check reads the tree again before the input; `--verify-id` acts on the tree the selector resolved on.
    static func verifierRereads(_ mode: Verifier.Mode) -> Bool {
        if case .change = mode { return true }
        return false
    }

    /// `--nth` as given; `--topmost` the match Android draws over the others, else `topmostPick`'s on each read (hit-test on a simulator).
    func matchPicker(query: AccessibilityQuery, backend: any DeviceBackend, device: DeviceID) -> MatchPicker? {
        Self.matchPicker(nth: nth, topmost: topmost, elementType: elementType, allowOffscreen: allowOffscreen, query: query, backend: backend, device: device)
    }

    static func matchPicker(nth: Int?, topmost: Bool, elementType: String?, allowOffscreen: Bool, query: AccessibilityQuery, backend: any DeviceBackend, device: DeviceID) -> MatchPicker? {
        if let nth { return { _ in .nth(nth) } }
        guard topmost else { return nil }
        let hitTester = backend as? any PointHitTesting
        return { roots in
            if hitTester == nil, let drawn = Self.drawnTopmost(roots: roots, query: query, elementType: elementType, allowOffscreen: allowOffscreen) {
                return drawn
            }
            return await Self.topmostPick(roots: roots, query: query, elementType: elementType, allowOffscreen: allowOffscreen) { point in
                guard let hitTester else { return UITree.hitChain(in: roots, at: point).last }
                return try? await hitTester.hitTest(at: point, on: device)
            }
        }
    }

    /// The match Android's drawing order puts over every other match; nil when any pair is ordered by tree order alone.
    static func drawnTopmost(roots: [UINode], query: AccessibilityQuery, elementType: String?, allowOffscreen: Bool) -> MatchPick? {
        let found = AccessibilityTargetResolver.candidates(roots: roots, query: query, elementType: elementType)
        let pool = allowOffscreen ? found.matches : found.onScreen
        guard pool.count > 1 else { return nil }
        for (index, match) in pool.enumerated() {
            var isTop = true
            for (otherIndex, other) in pool.enumerated() where otherIndex != index {
                guard let order = UITree.zOrder(of: match, over: other, in: roots), order.byDrawingOrder else { return nil }
                if !order.isAbove { isTop = false }
            }
            if isTop { return .nth(index + 1) }
        }
        return nil
    }

    /// The only match on the front page when a page is drawn over the others; else the first, front page first, whose own point hit-tests back to it; else the last on the front page.
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
        let stack = ScreenStack.build(roots: roots, viewport: found.viewport)
        let front = pool.indices.filter { !stack.isBeneath(pool[$0], in: roots) }
        if front.count == 1 {
            return .nth(front[0] + 1)
        }
        for index in front + pool.indices.filter({ !front.contains($0) }) {
            guard let resolution = try? AccessibilityTargetResolver.resolveTap(
                roots: roots, query: query, elementType: elementType, allowOffscreen: allowOffscreen, explainFailures: false, pick: .nth(index + 1)
            ), let matched = resolution.matched else { continue }
            if let hit = await hitTest(UIPoint(x: resolution.point.x, y: resolution.point.y)),
               AccessibilityTargetResolver.isFamily(hit, of: matched, in: roots) {
                return .nth(index + 1)
            }
        }
        return front.last.map { .nth($0 + 1) } ?? .last
    }

    /// Warns when a selector's point is outside the screen, which only `--allow-offscreen` lets through.
    static func warnIfOffScreen(subject: String, at point: (x: Double, y: Double), in tree: UITree) {
        guard let viewport = tree.viewport, !viewport.contains(UIPoint(x: point.x, y: point.y)) else {
            return
        }
        let pointText = VerifyOutput.pointDescription(x: point.x, y: point.y)
        let warning = "\(subject) at \(pointText) is outside the \(viewport.sizeSummary) screen; the tap may do nothing"
        Console.current.notice(.warning(warning, agent: warning + "."))
    }

    /// The keyboard and confident covers refuse unless `--allow-covered`; a tree-order guess warns, or with `--fail-if-covered` refuses; a disabled target refuses unless `--allow-disabled`.
    func coverCheck(query: AccessibilityQuery?, backend: any DeviceBackend, device: DeviceID) -> AccessibilityPoller.CoverCheck {
        let selector = query?.selectorDescription ?? ""
        var cover = TapCover(allowCovered: allowCovered, failIfCovered: failIfCovered, dryRun: dryRun, allowDisabled: allowDisabled)
        cover.query = query
        return { resolution, tree in
            try await Self.withKeyboardAdvice({
                try await cover.check(resolution, selector: selector, tree: tree, backend: backend, device: device)
            }, selector: selector, at: resolution.point, device: device, tree: tree)
        }
    }

    /// `tap` and `type --into-id` refuse; with `tree`, Back is offered only over docked keys, as over a toolbar it goes to the app.
    static func keyboardCoverError(selector: String, at point: (x: Double, y: Double), device: DeviceID, tree: UITree? = nil, appArgument: String = "", gesture: String = "tap") -> CLIError {
        let pointText = VerifyOutput.pointDescription(x: point.x, y: point.y)
        let back = device.platform == .android && tree.map(KeyboardDismiss.showsKeys(in:)) != false
        let hide: String
        if back {
            hide = "Hide the keyboard with `offsider button back` (or scroll the target above it)"
        } else if device.platform == .android {
            hide = "Scroll the target clear of the keyboard's toolbar (Back would go to the app, as only the toolbar shows)"
        } else {
            hide = "Dismiss the keyboard in the app (or scroll the target above it)"
        }
        return CLIError(
            errorDescription: "The keyboard covers \(selector) at \(pointText), so the \(gesture) would press a key. \(hide), then retry. Nothing was sent.",
            reason: .targetUnderKeyboard,
            hint: back ? "offsider button back\(appArgument) --device \(device.rawValue)" : "offsider describe-ui --summary\(appArgument) --device \(device.rawValue)"
        )
    }

    /// The cover check's keyboard refusal again with the tree it read, so its advice fits the keyboard on screen.
    @MainActor
    static func withKeyboardAdvice<Checked>(
        _ check: @MainActor () async throws -> Checked, selector: String, at point: (x: Double, y: Double), device: DeviceID, tree: UITree, gesture: String = "tap"
    ) async throws -> Checked {
        do {
            return try await check()
        } catch let error as CLIError where error.reason == .targetUnderKeyboard {
            throw keyboardCoverError(selector: selector, at: point, device: device, tree: tree, appArgument: CommandScope.current.appArgument(device: device.rawValue), gesture: gesture)
        }
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
