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
    }

    /// One read as the change detector and the change list each need it; `tree` is nil when the read failed.
    private struct Read {
        let tree: UITree?
        let snapshot: AccessibilitySnapshot
    }

    static let pollInterval: Duration = .milliseconds(200)
    static let screenshotSpacing: Duration = .milliseconds(350)
    static let screenshotCount = 3
    /// After-shots one attempt may take while a transition is still moving; a lagging stream may show it only from the second.
    static let maxScreenshots = 6
    /// The share of tiles that still differ across the latest after-shots while a transition is running; a caret or spinner moves far fewer.
    static let movingFraction = 0.1

    /// True while the oldest and newest of `prints` differ on more than `movingFraction` of their tiles.
    static func isMoving(_ prints: [ImageFingerprint]) -> Bool {
        guard prints.count >= 2, let first = prints.first, let last = prints.last else { return false }
        return ScreenCompare.outcome(changedFraction: first.changedFraction(comparedTo: last) ?? 1, threshold: movingFraction) == .changed
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
        let detector = detector ?? ChangeDetector(options: .init(ignoreText: ignoringText))

        let firstRead: Read
        if let initialTree {
            firstRead = Read(tree: initialTree, snapshot: AccessibilitySnapshot(tree: initialTree))
        } else {
            firstRead = await read(dependencies)
        }
        let first = firstRead.snapshot
        let firstShot = ignoringText ? nil : try? await dependencies.screenshot()
        let firstShotTime = dependencies.now()
        try await dependencies.sleep(pollInterval)
        var baselineRead = await read(dependencies)
        var baseline = baselineRead.snapshot
        let volatile = detector.volatileKeys(first, baseline)
        let volatileIdentities = Self.volatileIdentities(firstRead.tree, baselineRead.tree)
        let screenFrame = rootFrame(baseline) ?? rootFrame(first)
        if let tree = baselineRead.tree {
            try await beforeAction(tree)
        }
        let bands = await dependencies.bands()
        let gap = screenshotSpacing / .seconds(1) - (dependencies.now() - firstShotTime)
        if firstShot != nil, gap > 0 {
            try await dependencies.sleep(.seconds(gap))
        }
        var baselineShots = ignoringText ? [] : [firstShot, try? await dependencies.screenshot()].compactMap { $0 }
        var baselinePrints: [ImageFingerprint] = []

        for (index, style) in attempts.enumerated() {
            let attempt = Attempt(number: index + 1, style: style)
            try await action(attempt)

            let deadline = dependencies.now() + timeoutSeconds
            var seenChange: String?
            var pending: AccessibilitySnapshot?
            var lastUnchanged: Read?
            var seenRead: Read?
            if baseline.isKnown {
                repeat {
                    if let waitForChange = dependencies.waitForChange {
                        try await waitForChange(pollInterval)
                    } else {
                        try await dependencies.sleep(pollInterval)
                    }
                    let currentRead = await read(dependencies)
                    let current = currentRead.snapshot
                    switch detector.compare(baseline, current, ignoring: volatile) {
                    case .unknown:
                        continue
                    case .unchanged:
                        pending = nil
                        lastUnchanged = currentRead
                    case .changed(let summary):
                        seenChange = seenChange ?? summary
                        seenRead = currentRead
                        if let pending, detector.compare(pending, current, ignoring: volatile) == .unchanged {
                            return Outcome(verified: true, attempts: attempt.number, change: .accessibilityTree, style: style, summary: summary)
                                .listing(from: baselineRead.tree, to: currentRead.tree, skipping: volatileIdentities)
                        }
                        pending = current
                    }
                } while dependencies.now() < deadline
            }
            if let seenChange {
                return Outcome(verified: true, attempts: attempt.number, change: .accessibilityTree, style: style, summary: seenChange)
                    .listing(from: baselineRead.tree, to: seenRead?.tree, skipping: volatileIdentities)
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
                if ScreenChange.detect(before: baselinePrints, after: afterPrints) {
                    return Outcome(verified: true, attempts: attempt.number, change: .screenshot, style: style, summary: nil)
                }
                if let last = afterShots.last {
                    baselineShots = [last.data]
                    baselinePrints = afterPrints
                }
            }

            if index + 1 < attempts.count {
                if let lastUnchanged {
                    baselineRead = lastUnchanged
                    baseline = lastUnchanged.snapshot
                }
                onRetry(attempt, Attempt(number: index + 2, style: attempts[index + 1]))
            }
        }
        return Outcome(verified: false, attempts: attempts.count, change: .none, style: attempts.last ?? nil, summary: nil)
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
        let baseline: UITree
        if let initialTree { baseline = initialTree } else { baseline = try await dependencies.tree() }
        try refuseIfOnScreen(id, in: baseline)
        try await beforeAction(baseline)
        for (index, style) in attempts.enumerated() {
            let attempt = Attempt(number: index + 1, style: style)
            try await action(attempt)
            let deadline = dependencies.now() + timeoutSeconds
            repeat {
                if let waitForChange = dependencies.waitForChange {
                    try await waitForChange(pollInterval)
                } else {
                    try await dependencies.sleep(pollInterval)
                }
                if let tree = try? await dependencies.tree(), isOnScreen(id, in: tree) {
                    return Outcome(verified: true, attempts: attempt.number, change: .element, style: style, summary: "--id '\(id)' is on screen")
                }
            } while dependencies.now() < deadline
            if index + 1 < attempts.count {
                onRetry(attempt, Attempt(number: index + 2, style: attempts[index + 1]))
            }
        }
        return Outcome(verified: false, attempts: attempts.count, change: .none, style: attempts.last ?? nil, summary: nil)
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

    private static func read(_ dependencies: Dependencies) async -> Read {
        guard let tree = try? await dependencies.tree() else {
            return Read(tree: nil, snapshot: AccessibilitySnapshot(roots: []))
        }
        return Read(tree: tree, snapshot: AccessibilitySnapshot(tree: tree))
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
            bands: { await backend.volatileScreenBands(for: device) }
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
