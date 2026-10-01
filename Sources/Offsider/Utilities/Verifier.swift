import Foundation
import ImageIO
import OffsiderCore

/// Dispatches an input and waits for a settled tree change, then a screenshot change, retrying while neither appears.
@MainActor
struct Verifier {
    struct Dependencies {
        var snapshot: @MainActor () async throws -> AccessibilitySnapshot
        var screenshot: @MainActor () async throws -> Data
        var sleep: @MainActor (Duration) async throws -> Void
        var now: @MainActor () -> TimeInterval
        var bands: @MainActor () async -> ScreenBands = { ScreenBands(top: 60, bottom: 0) }
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
    }

    static let pollInterval: Duration = .milliseconds(200)
    static let screenshotSpacing: Duration = .milliseconds(350)
    static let screenshotCount = 3

    static func run(
        styles: [TapDeliveryStyle?],
        timeout: Duration,
        dependencies: Dependencies,
        detector: ChangeDetector = ChangeDetector(),
        onRetry: (Attempt, Attempt) -> Void = { _, _ in },
        action: (Attempt) async throws -> Void
    ) async throws -> Outcome {
        let attempts = styles.isEmpty ? [nil] : styles
        let timeoutSeconds = Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18

        let first = await read(dependencies)
        try await dependencies.sleep(pollInterval)
        var baseline = await read(dependencies)
        let volatile = detector.volatileKeys(first, baseline)
        let screenFrame = rootFrame(baseline) ?? rootFrame(first)
        let bands = await dependencies.bands()
        var baselineShot: Data? = try? await dependencies.screenshot()
        var baselinePrint: ImageFingerprint?

        for (index, style) in attempts.enumerated() {
            let attempt = Attempt(number: index + 1, style: style)
            try await action(attempt)

            let deadline = dependencies.now() + timeoutSeconds
            var seenChange: String?
            var pending: AccessibilitySnapshot?
            var lastUnchanged: AccessibilitySnapshot?
            if baseline.isKnown {
                repeat {
                    try await dependencies.sleep(pollInterval)
                    let current = await read(dependencies)
                    switch detector.compare(baseline, current, ignoring: volatile) {
                    case .unknown:
                        continue
                    case .unchanged:
                        pending = nil
                        lastUnchanged = current
                    case .changed(let summary):
                        seenChange = seenChange ?? summary
                        if let pending, detector.compare(pending, current, ignoring: volatile) == .unchanged {
                            return Outcome(verified: true, attempts: attempt.number, change: .accessibilityTree, style: style, summary: summary)
                        }
                        pending = current
                    }
                } while dependencies.now() < deadline
            }
            if let seenChange {
                return Outcome(verified: true, attempts: attempt.number, change: .accessibilityTree, style: style, summary: seenChange)
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
                if let lastUnchanged { baseline = lastUnchanged }
                onRetry(attempt, Attempt(number: index + 2, style: attempts[index + 1]))
            }
        }
        return Outcome(verified: false, attempts: attempts.count, change: .none, style: attempts.last ?? nil, summary: nil)
    }

    private static func read(_ dependencies: Dependencies) async -> AccessibilitySnapshot {
        (try? await dependencies.snapshot()) ?? AccessibilitySnapshot(roots: [])
    }

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
        Self(
            snapshot: { AccessibilitySnapshot(tree: try await backend.accessibilityTree(for: device)) },
            screenshot: { try await backend.screenshotPNG(for: device) },
            sleep: { duration in try await Task.sleep(for: duration) },
            now: { ProcessInfo.processInfo.systemUptime },
            bands: { await backend.volatileScreenBands(for: device) }
        )
    }
}
