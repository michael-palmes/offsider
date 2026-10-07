import Foundation
import ImageIO
import OffsiderCore

/// Dispatches an input and waits for a settled tree change, then a screenshot change, retrying while neither appears.
@MainActor
struct Verifier {
    struct Dependencies {
        var tree: @MainActor () async throws -> UITree
        var screenshot: @MainActor () async throws -> Data
        var sleep: @MainActor (Duration) async throws -> Void
        var now: @MainActor () -> TimeInterval
        var bands: @MainActor () async -> ScreenBands = { ScreenBands(top: 60, bottom: 0) }
        /// Between tree polls after the action, returning early when the screen may have changed; nil sleeps the interval.
        var waitForChange: (@MainActor (Duration) async throws -> Void)? = nil
        /// The device's cached tree, for learning which text is live before the input.
        var cachedRecord: @MainActor () async -> TreeCacheRecord? = { nil }
        /// Wall time, to date the first read against the cached tree.
        var date: @MainActor () -> Date = { Date() }
    }

    /// What proves the input worked: a settled change (text and frames optional), or one element coming on screen.
    enum Mode: Equatable {
        case change(ignoringText: Bool)
        case appearing(id: String)
    }

    struct Attempt: Equatable {
        let number: Int
        let style: TapDeliveryStyle?
    }

    struct Outcome: Equatable {
        let verified: Bool
        let attempts: Int
        let change: ChangeKind
        let style: TapDeliveryStyle?
        let summary: String?
        var changes: [VerifyChange] = []
        var changesTruncated = 0
        var note: VerifyNote?
        var ignored: [VerifyIgnored] = []
        var phases = VerifyPhases()
    }

    /// One read as the change detector and the change list each need it; `tree` is nil when the read failed.
    private struct Read {
        let tree: UITree?
        /// The read with LogBox toasts taken out, which every comparison uses.
        let compared: UITree?
        let snapshot: AccessibilitySnapshot
        let toasts: [LogBoxToast]

        init(_ tree: UITree?) {
            self.tree = tree
            guard let tree else {
                compared = nil
                snapshot = AccessibilitySnapshot(roots: [])
                toasts = []
                return
            }
            let stripped = LiveText.withoutLogBoxToasts(tree)
            compared = stripped.tree
            snapshot = AccessibilitySnapshot(tree: stripped.tree)
            toasts = stripped.toasts.isEmpty ? [] : KnownOverlays.logBoxToasts(in: tree.roots, viewport: tree.viewport)
        }
    }

    static let pollInterval: Duration = .milliseconds(200)
    static let screenshotSpacing: Duration = .milliseconds(350)
    static let screenshotCount = 3
    /// After-shots one attempt may take while a transition is still moving; a lagging stream may show it only from the second.
    static let maxScreenshots = 6
    /// Targets whose effect the tree always shows as a state change, so no baseline screenshot is taken for them.
    static let stateRoles: Set<UIRole> = [.switch, .checkbox, .radioButton]

    /// True while the oldest and newest of `prints` differ on more than `ScreenChange.movingFraction` of their tiles.
    static func isMoving(_ prints: [ImageFingerprint]) -> Bool {
        guard prints.count >= 2, let first = prints.first, let last = prints.last else { return false }
        return ScreenCompare.outcome(changedFraction: first.changedFraction(comparedTo: last) ?? 1, threshold: ScreenChange.movingFraction) == .changed
    }

    /// While the screen moves: one after-shot past `screenshotCount` always, more only before the attempt's deadline, never past `maxScreenshots`.
    static func takesAnotherShot(taken: Int, moving: Bool, withinDeadline: Bool) -> Bool {
        moving && taken < maxScreenshots && (taken == screenshotCount || withinDeadline)
    }

    /// `initialTree`, the tree the selector was resolved on, stands in for the first read; `beforeAction` sees the second.
    static func run(
        styles: [TapDeliveryStyle?],
        timeout: Duration,
        dependencies: Dependencies,
        mode: Mode = .change(ignoringText: false),
        detector: ChangeDetector? = nil,
        initialTree: UITree? = nil,
        target: UINode? = nil,
        beforeAction: (UITree) async throws -> Void = { _ in },
        onRetry: (Attempt, Attempt) -> Void = { _, _ in },
        action: (Attempt) async throws -> Void
    ) async throws -> Outcome {
        let attempts = styles.isEmpty ? [nil] : styles
        let timeoutSeconds = Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18
        let ignoringText: Bool
        switch mode {
        case .appearing(let id):
            return try await runAppearing(
                id: id, attempts: attempts, timeoutSeconds: timeoutSeconds, dependencies: dependencies,
                initialTree: initialTree, beforeAction: beforeAction, onRetry: onRetry, action: action
            )
        case .change(let ignore):
            ignoringText = ignore
        }
        let detector = detector ?? ChangeDetector(options: .init(ignoreText: ignoringText, ignoreFrames: ignoringText))
        let start = dependencies.now()
        var phases = VerifyPhases()

        let firstRead: Read
        if let initialTree {
            firstRead = Read(initialTree)
        } else {
            firstRead = Read(try? await dependencies.tree())
        }
        let first = firstRead.snapshot
        let firstReadAt = dependencies.date()
        let capturesBaseline = !ignoringText && !(target.map { stateRoles.contains($0.role) } ?? false)
        // With a tree to catch the change, the baseline capture runs alongside the reads before the input.
        let capture: Task<Data?, Never>? = capturesBaseline && first.isKnown
            ? Task { await Timings.measure("baseline-capture") { try? await dependencies.screenshot() } }
            : nil
        defer { capture?.cancel() }
        // Without a tree to catch the change, a second before-shot lets motion the input starts count.
        let firstShot = capturesBaseline && !first.isKnown ? try? await dependencies.screenshot() : nil
        let firstShotTime = dependencies.now()
        var live: Set<String> = []
        if !ignoringText, let tree = firstRead.tree {
            live = LiveText.learn(cached: await dependencies.cachedRecord(), first: tree, readAt: firstReadAt, detector: detector)
        }
        try await dependencies.sleep(pollInterval)
        var baselineRead = Read(try? await dependencies.tree())
        var baseline = baselineRead.snapshot
        let volatile = detector.volatileKeys(first, baseline)
        let volatileIdentities = Self.volatileIdentities(firstRead.compared, baselineRead.compared)
        let screenFrame = rootFrame(baseline) ?? rootFrame(first)
        let targetIsToast = target.map { node in
            (baselineRead.tree ?? firstRead.tree)?.viewport.map { KnownOverlays.logBoxToast(node, viewport: $0) != nil } ?? false
        } ?? false
        if let tree = baselineRead.tree {
            try await beforeAction(tree)
        }
        let bands = await dependencies.bands()
        phases.settle = dependencies.now() - start
        let baselineStart = dependencies.now()
        var baselineShots: [Data] = []
        if let capture {
            baselineShots = await capture.value.map { [$0] } ?? []
        } else if capturesBaseline {
            let gap = screenshotSpacing / .seconds(1) - (dependencies.now() - firstShotTime)
            if firstShot != nil, gap > 0 {
                try await dependencies.sleep(.seconds(gap))
            }
            baselineShots = [firstShot, try? await dependencies.screenshot()].compactMap { $0 }
        }
        phases.baseline = dependencies.now() - baselineStart
        var baselinePrints: [ImageFingerprint] = []
        var ignored: [VerifyIgnored] = []

        func finish(_ outcome: Outcome, attemptStart: TimeInterval) -> Outcome {
            var outcome = outcome
            phases.verify += dependencies.now() - attemptStart
            outcome.phases = phases
            outcome.ignored = ignored
            return outcome
        }

        func note(_ names: [String], _ reason: VerifyIgnored.Reason) {
            for name in names where !ignored.contains(where: { $0.node == name }) {
                ignored.append(VerifyIgnored(node: name, reason: reason))
            }
        }

        /// What this read changed that the comparison leaves out, noted for the report.
        func noteIgnored(_ current: Read) {
            guard current.snapshot.isKnown, baseline.isKnown else { return }
            note(detector.liveChanges(baseline, current.snapshot, live: live), .live)
            note(detector.keyChanges(baseline, current.snapshot, keys: volatile), .volatile)
            if current.toasts != baselineRead.toasts {
                note(["LogBox toast"], .toast)
            }
        }

        func verified(_ summary: String, read current: Read, attempt: Attempt, attemptStart: TimeInterval) -> Outcome {
            finish(
                Outcome(verified: true, attempts: attempt.number, change: .accessibilityTree, style: attempt.style, summary: summary)
                    .listing(
                        from: baselineRead.compared.map { detector.maskingLive($0, live: live) },
                        to: current.compared.map { detector.maskingLive($0, live: live) },
                        skipping: volatileIdentities
                    ),
                attemptStart: attemptStart
            )
        }

        for (index, style) in attempts.enumerated() {
            let attempt = Attempt(number: index + 1, style: style)
            let dispatchStart = dependencies.now()
            try await Timings.measure("dispatch") { try await action(attempt) }
            phases.dispatch += dependencies.now() - dispatchStart
            let attemptStart = dependencies.now()

            let deadline = dependencies.now() + timeoutSeconds
            var seenChange = false
            var pending: AccessibilitySnapshot?
            var lastUnchanged: Read?
            var lastRead: Read?
            if baseline.isKnown {
                let polled: Outcome? = try await Timings.measure("verify-poll") {
                    repeat {
                        if let waitForChange = dependencies.waitForChange {
                            try await waitForChange(pollInterval)
                        } else {
                            try await dependencies.sleep(pollInterval)
                        }
                        let currentRead = Read(try? await dependencies.tree())
                        let current = currentRead.snapshot
                        if !targetIsToast, let before = baselineRead.tree, let after = currentRead.tree, LiveText.logBoxOpened(before: before, after: after) {
                            return finish(
                                Outcome(verified: false, attempts: attempt.number, change: .none, style: style, summary: nil, note: .logBoxOpened),
                                attemptStart: attemptStart
                            )
                        }
                        noteIgnored(currentRead)
                        switch detector.compare(baseline, current, ignoring: volatile, live: live) {
                        case .unknown:
                            continue
                        case .unchanged:
                            pending = nil
                            lastUnchanged = currentRead
                            lastRead = currentRead
                        case .changed(let summary):
                            seenChange = true
                            lastRead = currentRead
                            if let pending, detector.compare(pending, current, ignoring: volatile, live: live) == .unchanged {
                                return verified(summary, read: currentRead, attempt: attempt, attemptStart: attemptStart)
                            }
                            pending = current
                        }
                    } while dependencies.now() < deadline
                    return nil
                }
                if let polled { return polled }
            }
            // A change that never settled counts only while the latest read still shows it.
            if seenChange, let lastRead, case .changed(let summary) = detector.compare(baseline, lastRead.snapshot, ignoring: volatile, live: live) {
                return verified(summary, read: lastRead, attempt: attempt, attemptStart: attemptStart)
            }

            if !ignoringText, let shot = baselineShots.last {
                let exclusion = bandPixels(pngData: shot, screenFrame: screenFrame, bands: bands)
                func fingerprint(_ data: Data) -> ImageFingerprint? {
                    ImageFingerprint(
                        pngData: data, excludingTopPixels: exclusion.top, excludingBottomPixels: exclusion.bottom,
                        excludingLeftPixels: exclusion.left, excludingRightPixels: exclusion.right, tolerance: bands.noiseTolerance
                    )
                }
                if baselinePrints.isEmpty {
                    baselinePrints = baselineShots.compactMap(fingerprint)
                }
                var afterShots: [(data: Data, print: ImageFingerprint)] = []
                var shotIndex = 0
                while shotIndex < screenshotCount || Self.takesAnotherShot(
                    taken: shotIndex, moving: Self.isMoving(afterShots.suffix(screenshotCount).map(\.print)), withinDeadline: dependencies.now() < deadline
                ) {
                    if shotIndex > 0 { try await dependencies.sleep(screenshotSpacing) }
                    shotIndex += 1
                    if let data = try? await dependencies.screenshot(), let print = fingerprint(data) {
                        afterShots.append((data, print))
                    }
                }
                let afterPrints = afterShots.suffix(screenshotCount).map(\.print)
                let explained = detector.frames(of: volatile, live: live, in: baseline)
                    + (baselineRead.toasts + (lastRead?.toasts ?? [])).map { AccessibilitySnapshot.Frame(x: $0.frame.x, y: $0.frame.y, width: $0.frame.width, height: $0.frame.height) }
                let skipped = afterPrints.last.map { Self.tiles(under: explained, in: $0, screenFrame: screenFrame) } ?? []
                if ScreenChange.detect(before: baselinePrints, after: afterPrints, ignoring: skipped) {
                    return finish(Outcome(verified: true, attempts: attempt.number, change: .screenshot, style: style, summary: nil), attemptStart: attemptStart)
                }
                if let last = afterShots.last {
                    baselineShots = [last.data]
                    baselinePrints = afterPrints
                }
            }

            // A slow push may land after the poll: one more read before any retry, so it verifies on this attempt.
            if baseline.isKnown {
                let lateRead = Read(try? await dependencies.tree())
                noteIgnored(lateRead)
                if case .changed(let summary) = detector.compare(baseline, lateRead.snapshot, ignoring: volatile, live: live) {
                    return verified(summary, read: lateRead, attempt: attempt, attemptStart: attemptStart)
                }
                if lateRead.snapshot.isKnown {
                    lastUnchanged = lateRead
                }
            }

            // A real effect taken for live text could be undone by a second input, so nothing is retried once anything was left out.
            let retrying = index + 1 < attempts.count && ignored.isEmpty
            phases.verify += dependencies.now() - attemptStart
            guard retrying else {
                var outcome = Outcome(verified: false, attempts: attempt.number, change: .none, style: style, summary: nil)
                outcome.phases = phases
                outcome.ignored = ignored
                return outcome
            }
            if let lastUnchanged {
                baselineRead = lastUnchanged
                baseline = lastUnchanged.snapshot
            }
            onRetry(attempt, Attempt(number: index + 2, style: attempts[index + 1]))
        }
        var outcome = Outcome(verified: false, attempts: attempts.count, change: .none, style: attempts.last ?? nil, summary: nil)
        outcome.phases = phases
        outcome.ignored = ignored
        return outcome
    }

    /// Refuses before any input when the element is already on screen, then waits up to the timeout per attempt for it to come on screen.
    private static func runAppearing(
        id: String,
        attempts: [TapDeliveryStyle?],
        timeoutSeconds: TimeInterval,
        dependencies: Dependencies,
        initialTree: UITree?,
        beforeAction: (UITree) async throws -> Void,
        onRetry: (Attempt, Attempt) -> Void,
        action: (Attempt) async throws -> Void
    ) async throws -> Outcome {
        let start = dependencies.now()
        var phases = VerifyPhases()
        let baseline: UITree
        if let initialTree { baseline = initialTree } else { baseline = try await dependencies.tree() }
        try refuseIfOnScreen(id, in: baseline)
        try await beforeAction(baseline)
        phases.settle = dependencies.now() - start
        for (index, style) in attempts.enumerated() {
            let attempt = Attempt(number: index + 1, style: style)
            let dispatchStart = dependencies.now()
            try await Timings.measure("dispatch") { try await action(attempt) }
            phases.dispatch += dependencies.now() - dispatchStart
            let attemptStart = dependencies.now()
            let deadline = dependencies.now() + timeoutSeconds
            repeat {
                if let waitForChange = dependencies.waitForChange {
                    try await waitForChange(pollInterval)
                } else {
                    try await dependencies.sleep(pollInterval)
                }
                if let tree = try? await dependencies.tree(), isOnScreen(id, in: tree) {
                    phases.verify += dependencies.now() - attemptStart
                    var outcome = Outcome(verified: true, attempts: attempt.number, change: .element, style: style, summary: "--id '\(id)' is on screen")
                    outcome.phases = phases
                    return outcome
                }
            } while dependencies.now() < deadline
            phases.verify += dependencies.now() - attemptStart
            if index + 1 < attempts.count {
                onRetry(attempt, Attempt(number: index + 2, style: attempts[index + 1]))
            }
        }
        var outcome = Outcome(verified: false, attempts: attempts.count, change: .none, style: attempts.last ?? nil, summary: nil)
        outcome.phases = phases
        return outcome
    }

    /// `--verify-id` cannot prove an input when its element shows already; the refusal says whether this command sent anything before it.
    static func refuseIfOnScreen(_ id: String, in tree: UITree) throws {
        guard isOnScreen(id, in: tree) else { return }
        let sent = DispatchTracker.current.state == .no ? "Nothing was sent." : "Only earlier input, such as the tap that focused the field, was sent."
        throw CLIError(
            errorDescription: "--verify-id '\(id)' is already on screen before the input, so it cannot show the input worked. \(sent)",
            reason: .verifyTargetPresent,
            hint: "Pass an id that only the next screen has, or use --verify."
        )
    }

    /// On screen when the tree has a screen to compare with; any match otherwise.
    static func isOnScreen(_ id: String, in tree: UITree) -> Bool {
        let found = AccessibilityTargetResolver.candidates(roots: tree.roots, query: .id(id), elementType: nil)
        return !(found.viewport == nil ? found.matches : found.onScreen).isEmpty
    }

    /// Nodes that differed between the two reads before the action, left out of the change list as the detector leaves them out of its comparison.
    private static func volatileIdentities(_ first: UITree?, _ second: UITree?) -> Set<String> {
        guard let first, let second else { return [] }
        return Set(TreeDiff.diff(old: first, new: second, filter: changeFilter).entries.map(\.key))
    }

    nonisolated static let changeFilter = UITreeFilter(labelled: true)

    private static func rootFrame(_ snapshot: AccessibilitySnapshot) -> AccessibilitySnapshot.Frame? {
        snapshot.roots.lazy.compactMap(\.frame).first { $0.width > 0 && $0.height > 0 }
    }

    /// The tiles of `print` under `frames` (points), while the capture is upright; none when its shape disagrees with the screen's.
    static func tiles(under frames: [AccessibilitySnapshot.Frame], in print: ImageFingerprint, screenFrame: AccessibilitySnapshot.Frame?) -> Set<Int> {
        guard !frames.isEmpty, let screenFrame, screenFrame.width > 0, screenFrame.height > 0,
              (print.width >= print.height) == (screenFrame.width >= screenFrame.height) else {
            return []
        }
        let scale = Double(print.width) / screenFrame.width
        let rects = frames.map { frame in
            let left = ((frame.x - screenFrame.x) * scale).rounded(.down)
            let top = ((frame.y - screenFrame.y) * scale).rounded(.down)
            let right = ((frame.x - screenFrame.x + frame.width) * scale).rounded(.up)
            let bottom = ((frame.y - screenFrame.y + frame.height) * scale).rounded(.up)
            return PixelRect(x: Int(left), y: Int(top), width: Int(right - left), height: Int(bottom - top))
        }
        return print.tiles(intersecting: rects)
    }

    /// Portrait only, unless the bands hold in every orientation and say how the raw screenshot turns upright.
    static func bandPixels(pngData: Data, screenFrame: AccessibilitySnapshot.Frame?, bands: ScreenBands) -> (top: Int, bottom: Int, left: Int, right: Int) {
        guard let screenFrame, bands.everyOrientation || screenFrame.height >= screenFrame.width,
              let source = CGImageSourceCreateWithData(pngData as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let pixelWidth = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              let pixelHeight = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue,
              screenFrame.width > 0, screenFrame.height > 0 else {
            return (0, 0, 0, 0)
        }
        guard bands.everyOrientation else {
            let scale = pixelWidth / screenFrame.width
            return (Int((bands.top * scale).rounded()), Int((bands.bottom * scale).rounded()), 0, 0)
        }
        return bands.screenshotPixels(scale: max(pixelWidth, pixelHeight) / max(screenFrame.width, screenFrame.height))
    }
}

extension Verifier.Dependencies {
    static func live(backend: any DeviceBackend, device: DeviceID) -> Self {
        var dependencies = Self(
            tree: { try await backend.accessibilityTree(for: device) },
            screenshot: { try await backend.screenshotPNG(for: device) },
            sleep: { duration in try await Task.sleep(for: duration) },
            now: { ProcessInfo.processInfo.systemUptime },
            bands: { await backend.volatileScreenBands(for: device) },
            cachedRecord: { await TreeCache.load(for: device, backend: backend) }
        )
        if let waiting = backend as? any AccessibilityChangeWaiting {
            dependencies.waitForChange = { duration in
                _ = try await waiting.waitForAccessibilityChange(on: device, timeout: duration)
            }
        }
        return dependencies
    }
}

extension Verifier.Outcome {
    /// Adds the capped change list between the baseline and the read that showed the change, and the keyboard note.
    func listing(from baseline: UITree?, to current: UITree?, skipping volatile: Set<String>) -> Self {
        guard let baseline, let current else { return self }
        let full = TreeDiff.diff(old: baseline, new: current, filter: Verifier.changeFilter)
        let diff = TreeDiff(entries: full.entries.filter { !volatile.contains($0.key) }, lineCount: full.lineCount, truncated: full.truncated)
        let capped = diff.cappedChanges()
        var outcome = self
        outcome.changes = capped.changes
        outcome.changesTruncated = capped.truncated
        outcome.note = diff.keyboardOnlyClosed(old: baseline, new: current) ? .keyboardClosed : nil
        return outcome
    }
}
