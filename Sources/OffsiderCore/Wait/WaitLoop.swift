import Foundation

/// What the wait loop reads and how it passes time, injected so tests need no device and no real clock.
public struct WaitSources {
    public var tree: @MainActor () async throws -> UITree
    /// The region, or the whole screen, as the caller prepares it.
    public var fingerprint: @MainActor () async throws -> ImageFingerprint
    public var sleep: @MainActor (Duration) async throws -> Void
    public var now: @MainActor () -> TimeInterval
    /// Read once when an element condition is not met, on the last tree, to explain the miss; nil never reads.
    public var probe: (@MainActor (UITree) async -> PresentationFinding?)?
    /// Called once, the first time another app in front holds a wait up.
    public var onOtherApp: (@MainActor () -> Void)?

    public init(
        tree: @escaping @MainActor () async throws -> UITree,
        fingerprint: @escaping @MainActor () async throws -> ImageFingerprint,
        sleep: @escaping @MainActor (Duration) async throws -> Void,
        now: @escaping @MainActor () -> TimeInterval,
        probe: (@MainActor (UITree) async -> PresentationFinding?)? = nil,
        onOtherApp: (@MainActor () -> Void)? = nil
    ) {
        self.tree = tree
        self.fingerprint = fingerprint
        self.sleep = sleep
        self.now = now
        self.probe = probe
        self.onOtherApp = onOtherApp
    }
}

/// One look for an element: the node only when exactly one candidate qualifies.
public enum ElementProbe: Equatable, Sendable {
    case present(UINode?)
    case absent(reason: String)
    /// Nothing matched while the LogBox inspector hides the app, so nothing can until it closes.
    case blocked(LogBoxBlock)
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

/// What a selector that found nothing came closest to: a phrase for the failure line and the elements behind it.
public struct WaitNearMiss: Equatable, Sendable {
    public let summary: String
    public let candidates: [FailureCandidate]

    public init(summary: String, candidates: [FailureCandidate]) {
        self.summary = summary
        self.candidates = candidates
    }
}

extension ElementProbe {
    /// The reason a probe gives when nothing matched the selector at all.
    public static let notFound = "not found"

    /// True for `notFound`, alone or with a note after it such as `; LogBox inspector open`.
    static func foundNothing(_ reason: String) -> Bool {
        reason == notFound || reason.hasPrefix(notFound + ";")
    }
}

extension WaitCondition {
    var looksForElements: Bool {
        switch self {
        case .element, .anyElement: true
        case .settled, .region, .duration: false
        }
    }

    /// A `--region --changed` wait compares with its first capture, however long another app was in front.
    var keepsBaseline: Bool {
        if case .region(.changed, _, _) = self { return true }
        return false
    }

    var explain: ((UITree) -> WaitNearMiss?)? {
        switch self {
        case .element(_, _, _, let explain), .anyElement(_, _, let explain): explain
        case .settled, .region, .duration: nil
        }
    }
}

public enum WaitCondition {
    /// `stableFor` is how long the element must stay present (or gone) across reads before the wait is met; `explain` reads the last tree once when a wait for it times out not found.
    case element(probe: (UITree) -> ElementProbe, gone: Bool, stableFor: TimeInterval = 0, explain: ((UITree) -> WaitNearMiss?)? = nil)
    /// Met when the first of several selectors, in order, is present; each entry names its selector for the report.
    case anyElement([(selector: WaitMatch, probe: (UITree) -> ElementProbe)], stableFor: TimeInterval = 0, explain: ((UITree) -> WaitNearMiss?)? = nil)
    /// With `ignoreValues`, label and value changes do not count; with `gate`, a pass waits for a recent input's effect; `leaveOut` does not count at all.
    /// With `drawHold`, a tree-only wait whose input changed the tree also waits for the pixels to hold still, for at most that long after the tree last changed.
    case settled(by: SettleSource, quiet: TimeInterval, ignoreValues: Bool = false, gate: SettleGate? = nil, leaveOut: SettleLeaveOut = .none, drawHold: TimeInterval? = nil)
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
    /// For a selector that timed out not found: the closest elements on the last read.
    public var nearMiss: WaitNearMiss?
    /// For `--settled`: the part of the screen that kept moving, which `--ignore-id` or `--ignore-region` leaves out.
    public var movingPart: MovingPart?

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
        let snapshot = before.map { AccessibilitySnapshot(tree: $0, native: false) }.flatMap { $0.isKnown ? $0 : nil }
        let limit = snapshot == nil ? Self.floor : Self.hold
        guard sinceInput < limit else { return nil }
        self.sinceInput = max(0, sinceInput)
        self.before = snapshot
    }

    /// How long after the input the gate opens by itself.
    public var limit: TimeInterval { before == nil ? Self.floor : Self.hold }

    /// True when `tree`, masked as the cache masks it, differs from the screen before the input, compared without native types; `leaveOut` counts on neither side.
    public func showsEffect(in tree: UITree, ignoreValues: Bool, leaveOut: SettleLeaveOut = .none) -> Bool {
        guard let before else { return false }
        let detector = ChangeDetector(options: .init(ignoredIdentifiers: leaveOut.detectorIDs, ignoreText: ignoreValues))
        let masked = tree.redacted(OutputMasks.current.mask, scope: .cache)
        let now = AccessibilitySnapshot(tree: masked, native: false).leavingOut(leaveOut.regions)
        if case .changed = detector.compare(before.leavingOut(leaveOut.regions), now) {
            return true
        }
        return false
    }

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

/// What a `--settled` wait does not count: elements by id and rectangles, each with everything under it.
public struct SettleLeaveOut: Equatable, Sendable {
    public var ids: Set<String>
    public var regions: [PointRegion]

    public init(ids: Set<String> = [], regions: [PointRegion] = []) {
        self.ids = ids
        self.regions = regions
    }

    public static let none = SettleLeaveOut()

    /// As the detector's keys write them, with a UUID in an id reduced to `<uuid>`.
    var detectorIDs: Set<String> {
        Set(ids.compactMap(ChangeDetector.normalisedIdentifier))
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
        state.deadline = deadline
        var lastReason = "not checked"
        var lastTransient: Error?
        var otherApp: Error?
        var succeededOnce = false
        var lastBlock: LogBoxBlock?
        let gone = if case .element(_, let isGone, _, _) = condition { isGone } else { false }

        while true {
            do {
                let step = try await evaluate(condition, state: &state, sources: sources)
                succeededOnce = true
                otherApp = nil
                if step.met {
                    return WaitOutcome(met: true, elapsed: sources.now() - start, reason: step.reason, match: step.match, matched: step.matched)
                }
                lastReason = step.reason
                lastBlock = try holdBlock(step.block, gone: gone, state: &state, sources: sources)
            } catch where error.isOtherAppInFront {
                if otherApp == nil, timeout > 0, !state.notedOtherApp {
                    state.notedOtherApp = true
                    sources.onOtherApp?()
                }
                otherApp = error
                state.forgetReads(keepingBaseline: condition.keepsBaseline, now: sources.now())
                lastBlock = nil
                lastReason = error.localizedDescription
            } catch where error.isTransientFailure {
                state.metSince = nil
                state.metReads = 0
                state.blockedSince = nil
                state.blockedReads = 0
                lastBlock = nil
                state.missed = false
                otherApp = nil
                lastTransient = error
                lastReason = error.localizedDescription
            }

            let remaining = deadline - sources.now()
            guard remaining > 0 else { break }
            try await sources.sleep(.milliseconds(Int((min(interval, remaining) * 1000).rounded())))
        }

        if let otherApp {
            throw otherApp
        }
        if !succeededOnce, let lastTransient {
            throw lastTransient
        }
        if let lastBlock {
            throw WaitBlockedError(block: lastBlock, gone: gone)
        }
        if state.treeReads >= 2, !state.readableTree {
            throw WaitUnreadableError.settledTree
        }
        let elapsed = sources.now() - start
        if condition.looksForElements, let probe = sources.probe, let tree = state.lastTree, let finding = await probe(tree) {
            lastReason = finding.explaining(lastReason)
        }
        var outcome = WaitOutcome(met: false, elapsed: elapsed, reason: lastReason)
        outcome.onlyTextMoved = state.treeChanges > 0 && !state.structureMoved
        if case .settled(_, _, let ignoreValues, _, let leaveOut, _) = condition, state.moves >= 2, let move = state.lastMove {
            outcome.movingPart = ChangeDetector(options: .init(ignoredIdentifiers: leaveOut.detectorIDs, ignoreText: ignoreValues)).movingPart(move.before, move.after)
        }
        if state.missed, let tree = state.lastTree {
            outcome.nearMiss = condition.explain?(tree)
        }
        return outcome
    }

    /// "1.2 s" style: whole seconds without a fraction, others to one decimal.
    nonisolated public static func seconds(_ value: TimeInterval) -> String {
        let tenths = (value * 10).rounded() / 10
        if tenths == tenths.rounded() {
            return "\(Int(tenths)) s"
        }
        return unsafe String(format: "%.1f s", tenths)
    }

    private struct Step {
        let met: Bool
        let reason: String
        var match: UINode? = nil
        var matched: WaitMatch? = nil
        var block: LogBoxBlock? = nil
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
        /// When the tree last changed, and whether the gate's before read shows the input changed it.
        var treeChangedAt: TimeInterval?
        var inputChangedTree = false
        var deadline: TimeInterval = 0
        /// How many reads saw an element move, and the last two reads that did.
        var moves = 0
        var lastMove: (before: AccessibilitySnapshot, after: AccessibilitySnapshot)?
        var notedOtherApp = false
        /// When the LogBox inspector began to hide the app, and the reads since.
        var blockedSince: TimeInterval?
        var blockedReads = 0
        /// The last tree an element condition read, and whether a selector found nothing on it.
        var lastTree: UITree?
        var missed = false

        /// Another app was in front, so what the earlier reads saw no longer counts; a `--changed` wait keeps its first capture.
        mutating func forgetReads(keepingBaseline: Bool, now: TimeInterval) {
            snapshot = nil
            if !keepingBaseline { fingerprint = nil }
            quietSince = nil
            treeChangedAt = now
            reads = 0
            metSince = nil
            metReads = 0
            blockedSince = nil
            blockedReads = 0
            missed = false
        }
    }

    private static func evaluate(_ condition: WaitCondition, state: inout State, sources: WaitSources) async throws -> Step {
        switch condition {
        case .element(let probe, let gone, let stableFor, _):
            let step: Step
            let tree = try await sources.tree()
            state.lastTree = tree
            state.missed = false
            switch probe(tree) {
            case .present(let node):
                step = gone ? Step(met: false, reason: "still on screen") : Step(met: true, reason: "on screen", match: node)
            case .absent(let reason):
                step = Step(met: gone, reason: reason)
                state.missed = ElementProbe.foundNothing(reason)
            case .blocked(let block):
                step = Step(met: false, reason: LogBoxBlock.reason, block: block)
            }
            return dwell(step, stableFor: stableFor, gone: gone, state: &state, sources: sources)

        case .anyElement(let selectors, let stableFor, _):
            let tree = try await sources.tree()
            state.lastTree = tree
            state.missed = false
            var reasons: [String] = []
            var blocks: [LogBoxBlock] = []
            var step = Step(met: false, reason: "")
            for selector in selectors {
                switch selector.probe(tree) {
                case .present(let node):
                    step = Step(met: true, reason: "on screen", match: node, matched: selector.selector)
                case .absent(let reason):
                    reasons.append("--\(selector.selector.by) '\(selector.selector.text)' \(reason)")
                    state.missed = state.missed || ElementProbe.foundNothing(reason)
                    continue
                case .blocked(let block):
                    blocks.append(block)
                    reasons.append("--\(selector.selector.by) '\(selector.selector.text)' \(LogBoxBlock.reason)")
                    continue
                }
                break
            }
            if !step.met {
                step = Step(met: false, reason: reasons.joined(separator: "; "))
                if blocks.count == selectors.count, let first = blocks.first {
                    step.block = LogBoxBlock(subject: blocks.map(\.subject).joined(separator: " or "), minimize: first.minimize)
                }
            } else if state.metSelector != step.matched {
                state.metSince = nil
                state.metReads = 0
            }
            state.metSelector = step.matched
            return dwell(step, stableFor: stableFor, gone: false, state: &state, sources: sources)

        case .settled(let source, let quiet, let ignoreValues, let gate, let leaveOut, let drawHold):
            var change: String?
            let detector = ChangeDetector(options: .init(ignoredIdentifiers: leaveOut.detectorIDs, ignoreText: ignoreValues))
            if source != .screen {
                let tree = try await sources.tree()
                let whole = AccessibilitySnapshot(tree: tree)
                let snapshot = whole.leavingOut(leaveOut.regions)
                state.treeReads += 1
                state.readableTree = state.readableTree || whole.isKnown
                if let previous = state.snapshot {
                    switch detector.compare(previous, snapshot) {
                    case .unchanged: break
                    case .unknown: change = "accessibility tree not readable"
                    case .changed(let summary):
                        change = "tree still changing (\(summary))"
                        state.treeChanges += 1
                        state.treeChangedAt = sources.now()
                        if ChangeDetector(options: .init(ignoredIdentifiers: leaveOut.detectorIDs, ignoreText: true)).compare(previous, snapshot) != .unchanged {
                            state.structureMoved = true
                            state.moves += 1
                            state.lastMove = (previous, snapshot)
                        }
                    }
                }
                if let gate, !state.gateOpen, gate.showsEffect(in: tree, ignoreValues: ignoreValues, leaveOut: leaveOut) {
                    state.gateOpen = true
                    state.inputChangedTree = true
                }
                state.snapshot = snapshot
            }
            // With no read from before the input, its effect may already have landed, so a tree that looks still proves nothing.
            let watchesDraw = source == .tree && drawHold != nil && (state.inputChangedTree || gate?.before == nil)
            var drawing = false
            if source != .tree {
                let fingerprint = try await sources.fingerprint()
                if change == nil, let previous = state.fingerprint, previous.changedTiles(comparedTo: fingerprint)?.isEmpty != true {
                    change = "screen still changing"
                }
                state.fingerprint = fingerprint
            } else if watchesDraw {
                // A frame taken while the tree moves proves nothing, and a capture is the slow part on a phone.
                let fingerprint = change == nil ? try await drawnFrame(sources) : nil
                if let fingerprint, let previous = state.fingerprint, previous.changedTiles(comparedTo: fingerprint)?.isEmpty != true {
                    drawing = true
                }
                state.fingerprint = fingerprint
            }
            if watchesDraw, change == nil, let drawHold {
                let now = sources.now()
                let treeQuietSince = state.treeChangedAt ?? state.start
                // Pixels never fail a tree wait: a chart or a caret never stops, so past the hold, or at the deadline, the tree alone decides.
                if now - treeQuietSince + 1e-9 >= drawHold || now + 1e-9 >= state.deadline {
                    state.quietSince = treeQuietSince
                } else if drawing {
                    change = "screen still drawing"
                }
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

    /// One frame for the draw hold; nil when it cannot be read, since pixels never fail a tree wait. Another app in front still counts as that.
    private static func drawnFrame(_ sources: WaitSources) async throws -> ImageFingerprint? {
        do {
            return try await sources.fingerprint()
        } catch where !error.isOtherAppInFront {
            return nil
        }
    }

    /// Throws once the LogBox inspector has hidden the app for `WaitBlockedError.grace` over two reads or more; the step's block otherwise.
    private static func holdBlock(_ block: LogBoxBlock?, gone: Bool, state: inout State, sources: WaitSources) throws -> LogBoxBlock? {
        guard let block else {
            state.blockedSince = nil
            state.blockedReads = 0
            return nil
        }
        let now = sources.now()
        let since = state.blockedSince ?? now
        state.blockedSince = since
        state.blockedReads += 1
        if state.blockedReads >= 2, now - since + 1e-9 >= WaitBlockedError.grace {
            throw WaitBlockedError(block: block, gone: gone)
        }
        return block
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
