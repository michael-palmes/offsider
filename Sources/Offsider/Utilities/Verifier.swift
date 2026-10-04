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

    /// `initialTree`, the tree the selector was resolved on, stands in for the first read; `beforeAction` sees the second.
    static func run(
        styles: [TapDeliveryStyle?],
        timeout: Duration,
        dependencies: Dependencies,
        detector: ChangeDetector = ChangeDetector(),
        initialTree: UITree? = nil,
        beforeAction: (UITree) async throws -> Void = { _ in },
        onRetry: (Attempt, Attempt) -> Void = { _, _ in },
        action: (Attempt) async throws -> Void
    ) async throws -> Outcome {
        let attempts = styles.isEmpty ? [nil] : styles
        let timeoutSeconds = Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18

        let firstRead: Read
        if let initialTree {
            firstRead = Read(tree: initialTree, snapshot: AccessibilitySnapshot(tree: initialTree))
        } else {
            firstRead = await read(dependencies)
        }
        let first = firstRead.snapshot
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
        var baselineShot: Data? = try? await dependencies.screenshot()
        var baselinePrint: ImageFingerprint?

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

            if let shot = baselineShot {
                let exclusion = bandPixels(pngData: shot, screenFrame: screenFrame, bands: bands)
                if baselinePrint == nil {
                    baselinePrint = ImageFingerprint(pngData: shot, excludingTopPixels: exclusion.top, excludingBottomPixels: exclusion.bottom)
                }
                var afterShots: [Data] = []
                for shotIndex in 0..<screenshotCount {
                    if shotIndex > 0 { try await dependencies.sleep(screenshotSpacing) }
                    if let data = try? await dependencies.screenshot() { afterShots.append(data) }
                }
                let afterPrints = afterShots.compactMap {
                    ImageFingerprint(pngData: $0, excludingTopPixels: exclusion.top, excludingBottomPixels: exclusion.bottom)
                }
                if let before = baselinePrint, !afterPrints.isEmpty,
                   ScreenChange.detect(before: before, after: afterPrints) {
                    return Outcome(verified: true, attempts: attempt.number, change: .screenshot, style: style, summary: nil)
                }
                if let last = afterShots.last, let lastPrint = afterPrints.last {
                    baselineShot = last
                    baselinePrint = lastPrint
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

    /// Portrait only: screenshots are portrait-native, so the bands cannot be placed in landscape.
    static func bandPixels(pngData: Data, screenFrame: AccessibilitySnapshot.Frame?, bands: ScreenBands) -> (top: Int, bottom: Int) {
        guard let screenFrame, screenFrame.height >= screenFrame.width,
              let source = CGImageSourceCreateWithData(pngData as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let pixelWidth = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue else {
            return (0, 0)
        }
        let scale = pixelWidth / screenFrame.width
        return (Int((bands.top * scale).rounded()), Int((bands.bottom * scale).rounded()))
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
