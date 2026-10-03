import Foundation

/// What the wait loop reads and how it passes time, injected so tests need no device and no real clock.
public struct WaitSources {
    public var tree: @MainActor () async throws -> UITree
    /// The region, or the whole screen, as the caller prepares it.
    public var fingerprint: @MainActor () async throws -> ImageFingerprint
    public var sleep: @MainActor (Duration) async throws -> Void
    public var now: @MainActor () -> TimeInterval

    public init(
        tree: @escaping @MainActor () async throws -> UITree,
        fingerprint: @escaping @MainActor () async throws -> ImageFingerprint,
        sleep: @escaping @MainActor (Duration) async throws -> Void,
        now: @escaping @MainActor () -> TimeInterval
    ) {
        self.tree = tree
        self.fingerprint = fingerprint
        self.sleep = sleep
        self.now = now
    }
}

/// One look for an element: the node only when exactly one candidate qualifies.
public enum ElementProbe: Equatable, Sendable {
    case present(UINode?)
    case absent(reason: String)
}

public enum SettleSource: String, CaseIterable, Sendable {
    case tree
    case screen
    case both
}

public enum RegionMode: Sendable {
    case changed
    case stable
}

public enum WaitCondition {
    case element(probe: (UITree) -> ElementProbe, gone: Bool)
    case settled(by: SettleSource, quiet: TimeInterval)
    case region(mode: RegionMode, quiet: TimeInterval, threshold: Double)
    case duration(TimeInterval)
}

public struct WaitOutcome: Equatable, Sendable {
    public let met: Bool
    public let elapsed: TimeInterval
    /// Why it was met, or the last reason it was not.
    public let reason: String
    public let match: UINode?

    public init(met: Bool, elapsed: TimeInterval, reason: String, match: UINode? = nil) {
        self.met = met
        self.elapsed = elapsed
        self.reason = reason
        self.match = match
    }
}

/// A wait that could never be met because every read it compared was unreadable.
public struct WaitUnreadableError: LocalizedError, CustomStringConvertible, Equatable, Sendable {
    public let message: String

    public var errorDescription: String? { message }
    public var description: String { message }

    static let settledTree = WaitUnreadableError(
        message: "--settled could not read the accessibility tree: every read was empty or unreadable, so it cannot tell when the screen settles. Use --settle-by screen to compare screenshots instead."
    )
}

@MainActor
public enum WaitLoop {
    /// Reads at least once; with `timeout` 0 exactly once. Transient read failures count as not yet met.
    public static func run(
        _ condition: WaitCondition,
        timeout: TimeInterval,
        interval: TimeInterval,
        sources: WaitSources
    ) async throws -> WaitOutcome {
        let start = sources.now()
        if case .duration(let seconds) = condition {
            try await sources.sleep(.milliseconds(Int((seconds * 1000).rounded())))
            return WaitOutcome(met: true, elapsed: sources.now() - start, reason: "waited")
        }

        let deadline = start + timeout
        var state = State()
        var lastReason = "not checked"
        var lastTransient: Error?
        var succeededOnce = false

        while true {
            do {
                let step = try await evaluate(condition, state: &state, sources: sources)
                succeededOnce = true
                if step.met {
                    return WaitOutcome(met: true, elapsed: sources.now() - start, reason: step.reason, match: step.match)
                }
                lastReason = step.reason
            } catch where error.isTransientFailure {
                lastTransient = error
                lastReason = error.localizedDescription
            }

            let remaining = deadline - sources.now()
            guard remaining > 0 else { break }
            try await sources.sleep(.milliseconds(Int((min(interval, remaining) * 1000).rounded())))
        }

        if !succeededOnce, let lastTransient {
            throw lastTransient
        }
        if state.treeReads >= 2, !state.readableTree {
            throw WaitUnreadableError.settledTree
        }
        return WaitOutcome(met: false, elapsed: sources.now() - start, reason: lastReason)
    }

    /// "1.2 s" style: whole seconds without a fraction, others to one decimal.
    nonisolated public static func seconds(_ value: TimeInterval) -> String {
        let tenths = (value * 10).rounded() / 10
        if tenths == tenths.rounded() {
            return "\(Int(tenths)) s"
        }
        return String(format: "%.1f s", tenths)
    }

    private struct Step {
        let met: Bool
        let reason: String
        var match: UINode? = nil
    }

    /// The previous read and when the current quiet window began.
    private struct State {
        var snapshot: AccessibilitySnapshot?
        var fingerprint: ImageFingerprint?
        var quietSince: TimeInterval?
        var reads = 0
        var treeReads = 0
        var readableTree = false
    }

    private static func evaluate(_ condition: WaitCondition, state: inout State, sources: WaitSources) async throws -> Step {
        switch condition {
        case .element(let probe, let gone):
            switch probe(try await sources.tree()) {
            case .present(let node):
                return gone ? Step(met: false, reason: "still on screen") : Step(met: true, reason: "on screen", match: node)
            case .absent(let reason):
                return Step(met: gone, reason: reason)
            }

        case .settled(let source, let quiet):
            var change: String?
            if source != .screen {
                let snapshot = AccessibilitySnapshot(tree: try await sources.tree())
                state.treeReads += 1
                state.readableTree = state.readableTree || snapshot.isKnown
                if let previous = state.snapshot {
                    switch ChangeDetector().compare(previous, snapshot) {
                    case .unchanged: break
                    case .unknown: change = "accessibility tree not readable"
                    case .changed(let summary): change = "tree still changing (\(summary))"
                    }
                }
                state.snapshot = snapshot
            }
            if source != .tree {
                let fingerprint = try await sources.fingerprint()
                if change == nil, let previous = state.fingerprint, previous.changedTiles(comparedTo: fingerprint)?.isEmpty != true {
                    change = "screen still changing"
                }
                state.fingerprint = fingerprint
            }
            return quietStep(change: change, quiet: quiet, met: "settled", state: &state, sources: sources)

        case .region(let mode, let quiet, let threshold):
            let fingerprint = try await sources.fingerprint()
            switch mode {
            case .changed:
                guard let baseline = state.fingerprint else {
                    state.fingerprint = fingerprint
                    return Step(met: false, reason: "region unchanged")
                }
                guard let result = ScreenCompare.compare(baseline, fingerprint, threshold: threshold) else {
                    return Step(met: true, reason: "region changed size")
                }
                return result.outcome == .changed
                    ? Step(met: true, reason: result.summary)
                    : Step(met: false, reason: "region unchanged")
            case .stable:
                var change: String?
                if let previous = state.fingerprint,
                   ScreenCompare.compare(previous, fingerprint, threshold: threshold)?.outcome != .unchanged {
                    change = "region still changing"
                }
                state.fingerprint = fingerprint
                return quietStep(change: change, quiet: quiet, met: "region stable", state: &state, sources: sources)
            }

        case .duration:
            return Step(met: true, reason: "waited")
        }
    }

    /// Met once two reads exist and nothing has changed for `quiet`; a change restarts the window.
    private static func quietStep(change: String?, quiet: TimeInterval, met: String, state: inout State, sources: WaitSources) -> Step {
        state.reads += 1
        let now = sources.now()
        if change != nil || state.quietSince == nil {
            state.quietSince = now
        }
        if let change {
            return Step(met: false, reason: change)
        }
        let quietFor = now - (state.quietSince ?? now)
        if state.reads >= 2, quietFor + 1e-9 >= quiet {
            return Step(met: true, reason: met)
        }
        return Step(met: false, reason: "quiet for \(seconds(quietFor)) of \(seconds(quiet))")
    }
}
