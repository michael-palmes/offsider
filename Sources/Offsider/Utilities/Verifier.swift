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
        /// What hides values in the change list, as `describe-ui` hides them, and in the cached tree.
        var valueMask: @MainActor () async throws -> TreeValueMask = { .none }
        /// The tree with the shared on-screen judgement read for the `--verify-id` element, so one beneath a page or covered is not in front.
        var judge: @MainActor (UITree, String) async -> UITree = { tree, _ in tree }
        /// Asks, after a verified tree change shows another app, whether the app the input aimed at stopped; nil never asks.
        var appExit: AppExitCheck? = nil
    }

    /// Where `--verify-id`'s element is.
    enum Placement: Equatable {
        case front
        /// What a touch would reach instead, such as `beneath "Details"`.
        case hidden(String)
        case offScreen
        case absent

        /// Why it is not in front, as a failure names it.
        var reason: String? {
            switch self {
            case .front: return nil
            case .hidden(let why): return "it is \(why)"
            case .offScreen: return "it is off screen"
            case .absent: return "no element has that id"
            }
        }
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
        var textCheck: TextCheck?

        /// The same change and its list, unverified for `note`: the input was sent once.
        func unverified(_ note: VerifyNote) -> Outcome {
            var spent = Outcome(verified: false, attempts: attempts, change: change, style: style, summary: nil, note: note)
            spent.changes = changes
            spent.changesTruncated = changesTruncated
            spent.ignored = ignored
            spent.phases = phases
            spent.textCheck = textCheck
            return spent
        }
    }

    /// One read as the change detector and the change list each need it; `tree` is nil when the read failed.
    private struct Read {
        let tree: UITree?
        /// The read with LogBox toasts taken out, which every comparison uses.
        let compared: UITree?
        let snapshot: AccessibilitySnapshot
        let toasts: [LogBoxToast]

        /// `keepingBeneath` keeps a screen beneath a page in the comparison, for an input aimed at it.
        init(_ tree: UITree?, keepingBeneath: Bool = false) {
            self.tree = tree
            guard let tree else {
                compared = nil
                snapshot = AccessibilitySnapshot(roots: [])
                toasts = []
                return
            }
            let stripped = LiveText.withoutLogBoxToasts(tree)
            compared = keepingBeneath ? stripped.tree : LiveText.withoutBeneath(stripped.tree)
            snapshot = AccessibilitySnapshot(tree: compared ?? stripped.tree)
            toasts = stripped.toasts.isEmpty ? [] : KnownOverlays.logBoxToasts(in: tree.roots, viewport: tree.viewport)
        }
    }

    static let pollInterval: Duration = .milliseconds(200)
    static let screenshotSpacing: Duration = .milliseconds(350)
    static let screenshotCount = 3
    /// After-shots one attempt may take while a transition is still moving; a lagging stream may show it only from the second.
    static let maxScreenshots = 6
    /// Targets whose effect the tree always shows as a state change, so no baseline screenshot is taken for them.
    nonisolated static let stateRoles: Set<UIRole> = [.switch, .checkbox, .radioButton]

    /// True while the oldest and newest of `prints` differ on more than `ScreenChange.movingFraction` of their tiles.
    static func isMoving(_ prints: [ImageFingerprint]) -> Bool {
        guard prints.count >= 2, let first = prints.first, let last = prints.last else { return false }
        return ScreenCompare.outcome(changedFraction: first.changedFraction(comparedTo: last) ?? 1, threshold: ScreenChange.movingFraction) == .changed
    }

    /// While the screen moves: one after-shot past `screenshotCount` always, more only before the attempt's deadline, never past `maxScreenshots`.
    static func takesAnotherShot(taken: Int, moving: Bool, withinDeadline: Bool) -> Bool {
        moving && taken < maxScreenshots && (taken == screenshotCount || withinDeadline)
    }

    /// `initialTree`, the tree the selector was resolved on, stands in for the first read; `beforeAction` sees the second; a retry is held for one more window after a change that did not last, a failed read, a small screen change away from `targetArea` or `targetStays` false.
    /// `expectsDevMenu` says from the read before the input whether the input aims at the dev menu; nil when it opening says nothing.
    static func run(
        styles: [TapDeliveryStyle?],
        timeout: Duration,
        dependencies: Dependencies,
        mode: Mode = .change(ignoringText: false),
        detector: ChangeDetector? = nil,
        initialTree: UITree? = nil,
        target: UINode? = nil,
        targetStays: ((UITree) async -> Bool)? = nil,
        expectsDevMenu: ((UITree) -> Bool)? = nil,
        keyboardOnlyFails: Bool = false,
        targetArea: @MainActor () -> UIFrame? = { nil },
        typed: TypedExpectation? = nil,
        beforeAction: (UITree) async throws -> Void = { _ in },
        onRetry: (Attempt, Attempt) -> Void = { _, _ in },
        onHold: (Attempt) -> Void = { _ in },
        action: (Attempt) async throws -> Void
    ) async throws -> Outcome {
        let attempts = styles.isEmpty ? [nil] : styles
        let timeoutSeconds = Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18
        let ignoringText: Bool
        switch mode {
        case .appearing(let id):
            return try await runAppearing(
                id: id, attempts: attempts, timeoutSeconds: timeoutSeconds, dependencies: dependencies,
                initialTree: initialTree, beforeAction: beforeAction, onRetry: onRetry, onHold: onHold, action: action
            )
        case .change(let ignore):
            ignoringText = ignore
        }
        let detector = detector ?? ChangeDetector(options: .init(ignoreText: ignoringText, ignoreFrames: ignoringText))
        let start = dependencies.now()
        var phases = VerifyPhases()

        let firstTree: UITree?
        if let initialTree {
            firstTree = initialTree
        } else {
            firstTree = try? await dependencies.tree()
        }
        let keepsBeneath = target.flatMap { node in firstTree.map { ScreenStack.build(roots: $0.roots, viewport: $0.viewport).isBeneath(node, in: $0.roots) } } ?? false
        func read(_ tree: UITree?) -> Read { Read(tree, keepingBeneath: keepsBeneath) }
        let firstRead = read(firstTree)
        let first = firstRead.snapshot
        let firstApp = dependencies.appExit?.app(in: firstTree)
        /// The raw reads the last tree change was told from; never in the outcome, which output may print.
        var changedReads: (before: UITree?, after: UITree?)?
        /// A change to another app counts only while the app the input aimed at still runs; typed text is read back from the field.
        func confirmed(_ outcome: Outcome) async throws -> Outcome {
            guard outcome.verified else { return outcome }
            if let after = changedReads?.after { try await dependencies.appExit?.check(firstApp, latest: after) }
            guard let typed else { return outcome }
            let readStart = dependencies.now()
            var checked = try await readBack(typed, outcome: outcome, reads: changedReads, timeout: timeoutSeconds, dependencies: dependencies)
            checked.phases.verify += dependencies.now() - readStart
            return checked
        }
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
        let valueMask = try await dependencies.valueMask()
        var live: Set<String> = []
        if !ignoringText, let tree = firstRead.tree {
            // The cached tree's masked values are compared with this read masked alike, so they never count as live text.
            let masked = tree.redacted(valueMask, scope: .cache)
            live = LiveText.learn(cached: await dependencies.cachedRecord(), first: masked, readAt: firstReadAt, detector: detector)
        }
        try await dependencies.sleep(pollInterval)
        let secondRead = read(try? await dependencies.tree())
        // A failed read says nothing, so the first stands as the baseline, and the input is still watched for its whole window.
        var baselineRead = secondRead.snapshot.isKnown || !first.isKnown ? secondRead : firstRead
        var baseline = baselineRead.snapshot
        let volatile = detector.volatileKeys(first, baseline)
        let volatileIdentities = Self.volatileIdentities(firstRead.compared, baselineRead.compared)
        let screenFrame = rootFrame(baseline) ?? rootFrame(first)
        let targetIsToast = target.map { node in
            (baselineRead.tree ?? firstRead.tree)?.viewport.map { KnownOverlays.logBoxToast(node, viewport: $0) != nil } ?? false
        } ?? false
        if secondRead.snapshot.isKnown, let tree = secondRead.tree {
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

        /// With `keyboardOnlyFails`, a change that only closed the keyboard is no proof the control was pressed, and it is not sent again.
        func verified(read current: Read, attempt: Attempt, attemptStart: TimeInterval) -> Outcome {
            let before = baselineRead.compared.map { detector.maskingLive($0, live: live).redacted(valueMask) }
            let after = current.compared.map { detector.maskingLive($0, live: live).redacted(valueMask) }
            let listed = Outcome(verified: true, attempts: attempt.number, change: .accessibilityTree, style: attempt.style, summary: shownSummary(from: before, to: after))
                .listing(from: before, to: after, skipping: volatileIdentities)
            changedReads = (baselineRead.tree, current.tree)
            guard keyboardOnlyFails, listed.note == .keyboardClosed else { return finish(listed, attemptStart: attemptStart) }
            return finish(listed.unverified(.keyboardClosed), attemptStart: attemptStart)
        }

        /// What the read shows opened over the app that is no effect of this input.
        func surprise(_ current: Read) -> VerifyNote? {
            guard let before = baselineRead.tree, let after = current.tree else { return nil }
            if !targetIsToast, LiveText.logBoxOpened(before: before, after: after) { return .logBoxOpened }
            if let expectsDevMenu, !expectsDevMenu(before), DevMenu.read(before) == nil, DevMenu.read(after) != nil { return .devMenuOpened }
            return nil
        }

        /// What changed, told from the trees as output shows them, so it never quotes what they hide; nil when they read alike.
        func shownSummary(from before: UITree?, to after: UITree?) -> String? {
            guard let before, let after,
                  case .changed(let summary) = detector.compare(AccessibilitySnapshot(tree: before), AccessibilitySnapshot(tree: after), ignoring: volatile, live: live) else { return nil }
            return summary
        }

        func unverified(_ attempt: Attempt, note: VerifyNote? = nil) -> Outcome {
            var outcome = Outcome(verified: false, attempts: attempt.number, change: .none, style: attempt.style, summary: nil, note: note)
            outcome.phases = phases
            outcome.ignored = ignored
            return outcome
        }

        /// One window of polls, after-shots and a late read; `unsettled` when the tree changed and went back, or a read failed after a readable baseline.
        func check(_ attempt: Attempt, from attemptStart: TimeInterval) async throws -> (outcome: Outcome?, unsettled: Bool, latest: Read?, lastUnchanged: Read?) {
            let style = attempt.style
            let deadline = dependencies.now() + timeoutSeconds
            var seenChange = false
            var smallChange = false
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
                        let currentRead = read(try? await dependencies.tree())
                        let current = currentRead.snapshot
                        if let surprise = surprise(currentRead) {
                            return finish(
                                Outcome(verified: false, attempts: attempt.number, change: .none, style: style, summary: nil, note: surprise),
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
                        case .changed:
                            seenChange = true
                            lastRead = currentRead
                            if let pending, detector.compare(pending, current, ignoring: volatile, live: live) == .unchanged {
                                return verified(read: currentRead, attempt: attempt, attemptStart: attemptStart)
                            }
                            pending = current
                        }
                    } while dependencies.now() < deadline
                    return nil
                }
                if let polled { return (polled, false, nil, nil) }
            }
            // A change that never settled counts only while the latest read still shows it.
            if seenChange, let lastRead, case .changed = detector.compare(baseline, lastRead.snapshot, ignoring: volatile, live: live) {
                return (verified(read: lastRead, attempt: attempt, attemptStart: attemptStart), false, nil, nil)
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
                let near = afterPrints.last.map { print in Self.nearTiles(targetArea(), in: print, screenFrame: screenFrame) } ?? []
                switch ScreenChange.detect(before: baselinePrints, after: afterPrints, ignoring: skipped, near: near) {
                case .changed:
                    return (finish(Outcome(verified: true, attempts: attempt.number, change: .screenshot, style: style, summary: nil), attemptStart: attemptStart), false, nil, nil)
                case .small:
                    smallChange = true
                case .none:
                    break
                }
                if let last = afterShots.last {
                    baselineShots = [last.data]
                    baselinePrints = afterPrints
                }
            }

            // A slow push may land after the poll: one more read before any retry, so it verifies on this attempt.
            guard baseline.isKnown else { return (nil, smallChange, nil, lastUnchanged) }
            let lateRead = read(try? await dependencies.tree())
            if let surprise = surprise(lateRead) {
                return (finish(Outcome(verified: false, attempts: attempt.number, change: .none, style: style, summary: nil, note: surprise), attemptStart: attemptStart), false, nil, nil)
            }
            noteIgnored(lateRead)
            if case .changed = detector.compare(baseline, lateRead.snapshot, ignoring: volatile, live: live) {
                return (verified(read: lateRead, attempt: attempt, attemptStart: attemptStart), false, nil, nil)
            }
            if lateRead.snapshot.isKnown {
                lastUnchanged = lateRead
            }
            return (nil, seenChange || smallChange || !lateRead.snapshot.isKnown, lateRead, lastUnchanged)
        }

        for (index, style) in attempts.enumerated() {
            let attempt = Attempt(number: index + 1, style: style)
            let dispatchStart = dependencies.now()
            try await Timings.measure("dispatch") { try await action(attempt) }
            phases.dispatch += dependencies.now() - dispatchStart
            let attemptStart = dependencies.now()
            // Nothing to compare with: a second input would go out blind, and could flip back a switch the first one set.
            if !baseline.isKnown, baselineShots.isEmpty {
                try await dependencies.sleep(timeout)
                phases.verify += dependencies.now() - attemptStart
                return unverified(attempt, note: .unreadable)
            }
            let checked = try await check(attempt, from: attemptStart)
            if let outcome = checked.outcome { return try await confirmed(outcome) }

            // A real effect taken for live text could be undone by a second input, so live text holds the retry back.
            let retrying = index + 1 < attempts.count && !ignored.contains { $0.reason == .live }
            phases.verify += dependencies.now() - attemptStart
            guard retrying else { return unverified(attempt) }
            var moving = checked.unsettled
            if !moving, let targetStays, let tree = checked.latest?.tree {
                moving = await !targetStays(tree)
            }
            if moving {
                // A second input would land on whatever the change brings, so this one is watched for one more window instead.
                onHold(attempt)
                let watchStart = dependencies.now()
                if let outcome = try await check(attempt, from: watchStart).outcome { return try await confirmed(outcome) }
                phases.verify += dependencies.now() - watchStart
                return unverified(attempt, note: .unsettled)
            }
            if let lastUnchanged = checked.lastUnchanged {
                baselineRead = lastUnchanged
                baseline = lastUnchanged.snapshot
            }
            onRetry(attempt, Attempt(number: index + 2, style: attempts[index + 1]))
        }
        return unverified(Attempt(number: attempts.count, style: attempts.last ?? nil))
    }

    /// Refuses before any input when the element is already in front (one beneath a page or covered is not), then waits up to the timeout per attempt for it to come to the front.
    private static func runAppearing(
        id: String,
        attempts: [TapDeliveryStyle?],
        timeoutSeconds: TimeInterval,
        dependencies: Dependencies,
        initialTree: UITree?,
        beforeAction: (UITree) async throws -> Void,
        onRetry: (Attempt, Attempt) -> Void,
        onHold: (Attempt) -> Void,
        action: (Attempt) async throws -> Void
    ) async throws -> Outcome {
        let start = dependencies.now()
        var phases = VerifyPhases()
        let read: UITree
        if let initialTree { read = initialTree } else { read = try await dependencies.tree() }
        let baseline = await dependencies.judge(read, id)
        try refuseIfOnScreen(id, in: baseline)
        try await beforeAction(baseline)
        phases.settle = dependencies.now() - start
        var latest = baseline
        var lastReadFailed = false

        /// Polls one window for the element; true once it is in front.
        func watch() async throws -> Bool {
            let watchStart = dependencies.now()
            defer { phases.verify += dependencies.now() - watchStart }
            let deadline = watchStart + timeoutSeconds
            repeat {
                if let waitForChange = dependencies.waitForChange {
                    try await waitForChange(pollInterval)
                } else {
                    try await dependencies.sleep(pollInterval)
                }
                let read = Read(try? await dependencies.tree())
                lastReadFailed = !read.snapshot.isKnown
                if !lastReadFailed, let tree = read.tree {
                    latest = await dependencies.judge(tree, id)
                    if placement(of: id, in: latest) == .front { return true }
                }
            } while dependencies.now() < deadline
            return false
        }

        // Only a read identical in every element says the input may not have landed; a ticking clock or a failed read says nothing.
        func screenUnchanged() -> Bool {
            !lastReadFailed && ChangeDetector().compare(Read(baseline).snapshot, Read(latest).snapshot) == .unchanged
        }

        func outcome(_ attempt: Attempt, verified: Bool) -> Outcome {
            var outcome = Outcome(
                verified: verified, attempts: attempt.number, change: verified ? .element : .none, style: attempt.style,
                summary: verified ? "--id '\(id)' is on screen" : placement(of: id, in: latest).reason
            )
            if !verified, screenUnchanged() {
                outcome.note = .screenUnchanged
            }
            outcome.phases = phases
            return outcome
        }

        for (index, style) in attempts.enumerated() {
            let attempt = Attempt(number: index + 1, style: style)
            let dispatchStart = dependencies.now()
            try await Timings.measure("dispatch") { try await action(attempt) }
            phases.dispatch += dependencies.now() - dispatchStart
            if try await watch() { return outcome(attempt, verified: true) }
            guard index + 1 < attempts.count else { break }
            if !screenUnchanged() {
                // The screen is not as it was, so a second input would land on whatever it shows now.
                onHold(attempt)
                return outcome(attempt, verified: try await watch())
            }
            onRetry(attempt, Attempt(number: index + 2, style: attempts[index + 1]))
        }
        return outcome(Attempt(number: attempts.count, style: attempts.last ?? nil), verified: false)
    }

    /// A verified `type` whose field does not hold the text sent is unverified, with nothing sent again.
    private static func readBack(
        _ typed: TypedExpectation, outcome: Outcome, reads: (before: UITree?, after: UITree?)?, timeout: TimeInterval, dependencies: Dependencies
    ) async throws -> Outcome {
        let check = try await checkTypedText(typed, reads: reads, timeout: timeout, dependencies: dependencies)
        var checked = outcome
        checked.textCheck = check
        return check == .differs ? checked.unverified(.textDiffers) : checked
    }

    /// Whether the field holds `typed`'s text: the verified read first, then fresh reads for up to `timeout` while it differs, as a React Native field's value lags its keys.
    private static func checkTypedText(_ typed: TypedExpectation, reads: (before: UITree?, after: UITree?)?, timeout: TimeInterval, dependencies: Dependencies) async throws -> TextCheck {
        guard typed.judged else { return .unknown }
        var after = reads?.after
        if after == nil { after = try? await dependencies.tree() }
        let deadline = dependencies.now() + timeout
        while true {
            let check = after.map { typed.check(before: reads?.before, after: $0) } ?? .unknown
            guard check == .differs, dependencies.now() < deadline else { return check }
            try await dependencies.sleep(pollInterval)
            if let read = try? await dependencies.tree() { after = read }
        }
    }

    /// `--verify-id` cannot prove an input when its element is in front already; the refusal says whether this command sent anything before it.
    static func refuseIfOnScreen(_ id: String, in tree: UITree) throws {
        guard isOnScreen(id, in: tree) else { return }
        let sent = DispatchTracker.current.state == .no ? "Nothing was sent." : "Only earlier input, such as the tap that focused the field, was sent."
        throw CLIError(
            errorDescription: "--verify-id '\(id)' is already on screen before the input, so it cannot show the input worked. \(sent)",
            reason: .verifyTargetPresent,
            hint: "Pass an id that only the next screen has, or use --verify."
        )
    }

    /// In front when a touch would reach it by the tree's on-screen judgement, or on screen by frame when the tree carries none; any match when the tree has no screen.
    static func isOnScreen(_ id: String, in tree: UITree) -> Bool {
        placement(of: id, in: tree) == .front
    }

    /// `tree` with the shared on-screen judgement read for `id`'s element, hit-testing its point on a simulator even where nothing labelled overlaps it.
    static func judged(_ tree: UITree, id: String, backend: any DeviceBackend, device: DeviceID) async -> UITree {
        var judged = tree
        await FrontJudge.read(matching: [.id(id)], elementType: nil, in: &judged, backend: backend, device: device, everyPoint: true)
        return judged
    }

    static func placement(of id: String, in tree: UITree) -> Placement {
        let found = AccessibilityTargetResolver.candidates(roots: tree.roots, query: .id(id), elementType: nil)
        guard !found.matches.isEmpty else { return .absent }
        let shown = found.viewport == nil ? found.matches : found.onScreen
        guard !shown.isEmpty else { return .offScreen }
        guard let front = tree.front, !front.isEmpty else { return .front }
        var first: String?
        for node in shown {
            guard let reason = front.reason(for: node, in: tree.roots) else { return .front }
            first = first ?? reason
        }
        return first.map(Placement.hidden) ?? .front
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

    /// The tiles under `area`, a point when it has no size, and one tile around them; none without an area or a capture to map it to.
    static func nearTiles(_ area: UIFrame?, in print: ImageFingerprint, screenFrame: AccessibilitySnapshot.Frame?) -> Set<Int> {
        guard let area else { return [] }
        let frame = area.width > 0 && area.height > 0
            ? AccessibilitySnapshot.Frame(x: area.x, y: area.y, width: area.width, height: area.height)
            : AccessibilitySnapshot.Frame(x: area.x - 0.5, y: area.y - 0.5, width: 1, height: 1)
        return print.dilated(tiles(under: [frame], in: print, screenFrame: screenFrame))
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
    @MainActor
    static func live(backend: any DeviceBackend, device: DeviceID, watchdog: DeviceWatchdog = DeviceWatchdog()) -> Self {
        var dependencies = Self(
            tree: { try await watchdog.guardingInputRead(of: device) { try await backend.accessibilityTree(for: device) } },
            screenshot: { try await watchdog.guardingInputRead(of: device) { try await backend.screenshotPNG(for: device) } },
            sleep: { duration in try await Task.sleep(for: duration) },
            now: { ProcessInfo.processInfo.systemUptime },
            bands: { await backend.volatileScreenBands(for: device) },
            cachedRecord: { await TreeCache.load(for: device, backend: backend) },
            valueMask: { try AmbientMasks.treeMask(revealed: await TreeCache.revealedSecrets(for: device, backend: backend)) },
            judge: { tree, id in await Verifier.judged(tree, id: id, backend: backend, device: device) },
            appExit: (backend as? any AppLivenessReading).map { AppExitCheck(reader: $0, device: device) }
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
