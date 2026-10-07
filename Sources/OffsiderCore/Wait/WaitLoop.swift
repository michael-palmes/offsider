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
    /// `stableFor` is how long the element must stay present (or gone) across reads before the wait is met.
    case element(probe: (UITree) -> ElementProbe, gone: Bool, stableFor: TimeInterval = 0)
    /// Met when the first of several selectors, in order, is present; each entry names its selector for the report.
    case anyElement([(selector: WaitMatch, probe: (UITree) -> ElementProbe)], stableFor: TimeInterval = 0)
    /// With `ignoreValues`, label and value changes do not count; with `gate`, a pass waits for a recent input's effect.
    case settled(by: SettleSource, quiet: TimeInterval, ignoreValues: Bool = false, gate: SettleGate? = nil)
    case region(mode: RegionMode, quiet: TimeInterval, threshold: Double)
    case duration(TimeInterval)
}

/// One selector of a `wait --any`, as the report names it: `by` is `id`, `label` or `value`.
public struct WaitMatch: Equatable, Sendable {
    public let by: String
    public let text: String
    /// Its place among the selectors, from 1.
    public let position: Int
    public let of: Int

    public init(by: String, text: String, position: Int, of: Int) {
        self.by = by
        self.text = text
        self.position = position
        self.of = of
    }
}

public struct WaitOutcome: Equatable, Sendable {
    public let met: Bool
    public let elapsed: TimeInterval
    /// Why it was met, or the last reason it was not.
    public let reason: String
    public let match: UINode?
    /// Which selector of a `wait --any` was met.
    public let matched: WaitMatch?
    /// For `--settled`: every change the tree showed was to text, which `--ignore-values` leaves out.
    public var onlyTextMoved = false

    public init(met: Bool, elapsed: TimeInterval, reason: String, match: UINode? = nil, matched: WaitMatch? = nil) {
        self.met = met
        self.elapsed = elapsed
        self.reason = reason
        self.match = match
        self.matched = matched
    }
}

/// Holds a `--settled` pass after an input until a read differs from the screen before it, `hold` passes, or `floor` with no screen from before.
public struct SettleGate: Equatable, Sendable {
    public static let hold: TimeInterval = 2
    public static let floor: TimeInterval = 1

    /// Seconds from the input to the start of the wait.
    public let sinceInput: TimeInterval
    /// The screen before the input, when a read of it was kept.
    public let before: AccessibilitySnapshot?

    /// Nil when the input is already older than the gate would hold.
    public init?(sinceInput: TimeInterval, before: UITree?) {
        let snapshot = before.map(AccessibilitySnapshot.init(tree:)).flatMap { $0.isKnown ? $0 : nil }
        let limit = snapshot == nil ? Self.floor : Self.hold
        guard sinceInput < limit else { return nil }
        self.sinceInput = max(0, sinceInput)
        self.before = snapshot
    }

    /// How long after the input the gate opens by itself.
    public var limit: TimeInterval { before == nil ? Self.floor : Self.hold }

    /// The gate for a record's last input; none without one, when it is old, or when its command read the screen after it (a verified input).
    public static func after(_ record: TreeCacheRecord?, now: Date) -> SettleGate? {
        guard let record, let input = record.lastInputAt else { return nil }
        let since = now.timeIntervalSince(input)
        switch record.treeRole {
        case .postAction?:
            return nil
        case .preAction?:
            return SettleGate(sinceInput: since, before: record.tree)
        case .read?, nil:
            return SettleGate(sinceInput: since, before: nil)
        }
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
        state.start = start
        var lastReason = "not checked"
        var lastTransient: Error?
        var succeededOnce = false

        while true {
            do {
                let step = try await evaluate(condition, state: &state, sources: sources)
                succeededOnce = true
                if step.met {
                    return WaitOutcome(met: true, elapsed: sources.now() - start, reason: step.reason, match: step.match, matched: step.matched)
                }
                lastReason = step.reason
            } catch where error.isTransientFailure {
                state.metSince = nil
                state.metReads = 0
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
        var outcome = WaitOutcome(met: false, elapsed: sources.now() - start, reason: lastReason)
        outcome.onlyTextMoved = state.treeChanges > 0 && !state.structureMoved
        return outcome
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
        var matched: WaitMatch? = nil
    }

    /// The previous read and when the current quiet window began.
    private struct State {
        var snapshot: AccessibilitySnapshot?
        var fingerprint: ImageFingerprint?
        var quietSince: TimeInterval?
        var reads = 0
        var treeReads = 0
        var readableTree = false
        /// When an element condition began to hold, and the reads since; a miss resets both.
        var metSince: TimeInterval?
        var metReads = 0
        var metSelector: WaitMatch?
        var start: TimeInterval = 0
        /// A settle gate's state: set once a read showed the input's effect.
        var gateOpen = false
        var treeChanges = 0
        var structureMoved = false
    }

    private static func evaluate(_ condition: WaitCondition, state: inout State, sources: WaitSources) async throws -> Step {
        switch condition {
        case .element(let probe, let gone, let stableFor):
            let step: Step
            switch probe(try await sources.tree()) {
            case .present(let node):
                step = gone ? Step(met: false, reason: "still on screen") : Step(met: true, reason: "on screen", match: node)
            case .absent(let reason):
                step = Step(met: gone, reason: reason)
            }
            return dwell(step, stableFor: stableFor, gone: gone, state: &state, sources: sources)

        case .anyElement(let selectors, let stableFor):
            let tree = try await sources.tree()
            var reasons: [String] = []
            var step = Step(met: false, reason: "")
            for selector in selectors {
                switch selector.probe(tree) {
                case .present(let node):
                    step = Step(met: true, reason: "on screen", match: node, matched: selector.selector)
                case .absent(let reason):
                    reasons.append("--\(selector.selector.by) '\(selector.selector.text)' \(reason)")
                    continue
                }
                break
            }
            if !step.met {
                step = Step(met: false, reason: reasons.joined(separator: "; "))
            } else if state.metSelector != step.matched {
                state.metSince = nil
                state.metReads = 0
            }
            state.metSelector = step.matched
            return dwell(step, stableFor: stableFor, gone: false, state: &state, sources: sources)

        case .settled(let source, let quiet, let ignoreValues, let gate):
            var change: String?
            let detector = ChangeDetector(options: .init(ignoreText: ignoreValues))
            if source != .screen {
                let snapshot = AccessibilitySnapshot(tree: try await sources.tree())
                state.treeReads += 1
                state.readableTree = state.readableTree || snapshot.isKnown
                if let previous = state.snapshot {
                    switch detector.compare(previous, snapshot) {
                    case .unchanged: break
                    case .unknown: change = "accessibility tree not readable"
                    case .changed(let summary):
                        change = "tree still changing (\(summary))"
                        state.treeChanges += 1
                        if ChangeDetector(options: .init(ignoreText: true)).compare(previous, snapshot) != .unchanged {
                            state.structureMoved = true
                        }
                    }
                }
                if let before = gate?.before, case .changed = detector.compare(before, snapshot) {
                    state.gateOpen = true
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
            let step = quietStep(change: change, quiet: quiet, met: "settled", state: &state, sources: sources)
            guard step.met, let gate, !state.gateOpen else { return step }
            let sinceInput = gate.sinceInput + sources.now() - state.start
            if sinceInput + 1e-9 >= gate.limit {
                state.gateOpen = true
                return step
            }
            return Step(met: false, reason: "waiting for the last input's effect (\(seconds(sinceInput)) of \(seconds(gate.limit)) since it)")

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

    /// Holds a met step back until it has held on every read for `stableFor`, over two reads or more.
    private static func dwell(_ step: Step, stableFor: TimeInterval, gone: Bool, state: inout State, sources: WaitSources) -> Step {
        guard step.met else {
            state.metSince = nil
            state.metReads = 0
            return step
        }
        guard stableFor > 0 else { return step }
        let now = sources.now()
        let since = state.metSince ?? now
        state.metSince = since
        state.metReads += 1
        let heldFor = now - since
        let place = gone ? "gone" : "on screen"
        if state.metReads >= 2, heldFor + 1e-9 >= stableFor {
            return Step(met: true, reason: "\(place) for \(seconds(heldFor))", match: step.match, matched: step.matched)
        }
        return Step(met: false, reason: "\(place) for \(seconds(heldFor)) of \(seconds(stableFor))")
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
