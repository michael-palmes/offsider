import Foundation
import OffsiderCore

/// A resolution and the tree it came from, so callers reuse that tree instead of reading another.
struct Polled<T> {
    var value: T
    let tree: UITree
    /// True when the poll already saw two agreeing reads, so the target is at rest.
    var waited = false
    /// How the transition guard let the action go ahead; nil when it did not run.
    var settledBy: TransitionDecision?
}

/// Whether a selector waits out a transition an earlier input started before acting.
enum SettlePolicy {
    case off
    /// `record` is the device's cached tree, loaded before the first read.
    case guarded(record: TreeCacheRecord?)
}

@MainActor
struct AccessibilityPoller {
    /// `transientGrace` retries a transient tree failure for that long even without `--wait-timeout` (for `--verify`).
    static func resolveWithPolling(
        query: AccessibilityQuery,
        on backend: any DeviceBackend,
        device: DeviceID,
        waitTimeout: TimeInterval,
        pollInterval: TimeInterval,
        transientGrace: TimeInterval = 0,
        elementType: String? = nil,
        allowOffscreen: Bool = false,
        settle: SettlePolicy = .off,
        pick: MatchPicker? = nil,
        coverCheck: CoverCheck? = nil,
        coverSettle: TimeInterval = 0,
        readsHiddenCovers: Bool = false,
        watchdog: DeviceWatchdog = DeviceWatchdog(),
        logger: OffsiderLogger
    ) async throws -> Polled<TapResolution> {
        try await pollForResolution(
            query: query,
            waitTimeout: waitTimeout,
            pollInterval: pollInterval,
            transientGrace: transientGrace,
            elementType: elementType,
            allowOffscreen: allowOffscreen,
            settle: settle,
            pick: pick,
            coverCheck: coverCheck,
            coverSettle: coverSettle,
            logger: logger
        ) {
            try await watchdog.guardingInputRead(of: device) {
                await judged(
                    try await backend.accessibilityTree(for: device), query: query, elementType: elementType, allowOffscreen: allowOffscreen,
                    readsHiddenCovers: readsHiddenCovers, pick: pick, backend: backend, device: device
                )
            }
        }
    }

    /// `read` as a selector tap judges it: what the app hides filled in where it is needed, and several matches hit-tested.
    static func judged(
        _ read: UITree, query: AccessibilityQuery, elementType: String?, allowOffscreen: Bool, readsHiddenCovers: Bool, pick: MatchPicker?, backend: any DeviceBackend, device: DeviceID
    ) async -> UITree {
        // Android's every-view read is cheap, and the only way to see a hidden page over what the tree lists.
        let tree = readsHiddenCovers && read.platform == .android
            ? await backend.withGapsFilled(read, on: device)
            : await fillingGaps(read, for: [query], elementType: elementType, allowOffscreen: allowOffscreen, on: backend, device: device)
        return await judgingMatches(tree, query: query, elementType: elementType, pick: pick, backend: backend, device: device)
    }

    /// Several matches on a simulator: `tree` with the hit-tests that tell which one a touch reaches, read at once, which the cover check then reuses.
    static func judgingMatches(_ read: UITree, query: AccessibilityQuery, elementType: String?, pick: MatchPicker?, backend: any DeviceBackend, device: DeviceID) async -> UITree {
        var tree = read
        if pick == nil, backend is any PointHitTesting, tree.platform == .ios,
           AccessibilityTargetResolver.candidates(roots: tree.roots, query: query, elementType: elementType).onScreen.count > 1 {
            await FrontJudge.read(matching: [query], elementType: elementType, in: &tree, backend: backend, device: device)
        }
        return tree
    }

    /// `tree` with what the app hides from accessibility, read only when no query has a match to act on, so a selector that matches pays nothing.
    static func fillingGaps(
        _ tree: UITree, for queries: [AccessibilityQuery], elementType: String?, allowOffscreen: Bool = false, on backend: any DeviceBackend, device: DeviceID
    ) async -> UITree {
        let isMissing = { (query: AccessibilityQuery) in
            let found = AccessibilityTargetResolver.candidates(roots: tree.roots, query: query, elementType: elementType)
            return allowOffscreen ? found.matches.isEmpty : found.onScreen.isEmpty
        }
        guard queries.allSatisfy(isMissing) else { return tree }
        return await backend.withGapsFilled(tree, on: device)
    }

    /// Refuses (`target_covered`, `target_disabled`), warns or returns the tap to send for a resolved tap; `pollForResolution` retries a refusal until `--wait-timeout`.
    typealias CoverCheck = (TapResolution, UITree) async throws -> TapResolution

    static func pollForResolution(
        query: AccessibilityQuery,
        waitTimeout: TimeInterval,
        pollInterval: TimeInterval,
        transientGrace: TimeInterval = 0,
        elementType: String?,
        allowOffscreen: Bool = false,
        settle: SettlePolicy = .off,
        pick: MatchPicker? = nil,
        coverCheck: CoverCheck? = nil,
        coverSettle: TimeInterval = 0,
        logger: OffsiderLogger,
        clock: PollClock = .live,
        treeFetcher: () async throws -> UITree
    ) async throws -> Polled<TapResolution> {
        let start = clock.now()
        while true {
            let remaining = max(0, waitTimeout - (clock.now() - start))
            let polled: Polled<TapResolution>
            do {
                polled = try await pollOnce(
                    query: query, waitTimeout: remaining, pollInterval: pollInterval, transientGrace: transientGrace, elementType: elementType,
                    allowOffscreen: allowOffscreen, settle: settle, pick: pick, logger: logger, clock: clock, treeFetcher: treeFetcher
                )
            } catch where retryableMiss(error) != nil && clock.now() - start < waitTimeout {
                logger.info().log("\(retryableMiss(error)?.isOffScreen == true ? "Element off screen" : "Element not found") once the screen settled, retrying in \(pollInterval)s…")
                try await clock.sleep(.seconds(pollInterval))
                continue
            }
            guard let coverCheck else { return polled }
            do {
                var checked = polled
                checked.value = try await coverCheck(polled.value, polled.tree)
                return checked
            } catch where TapCover.isRefusal(error) && clock.now() - start < max(waitTimeout, coverSettle) {
                logger.info().log("Target covered, checking again in \(pollInterval)s…")
                try await clock.sleep(.seconds(pollInterval))
            } catch where TapCover.isKeyboardRefusal(error) && clock.now() - start < max(waitTimeout, TapCover.keyboardSettle) {
                logger.info().log("The keyboard covers the target, checking again in \(pollInterval)s…")
                try await clock.sleep(.seconds(pollInterval))
            } catch where TapCover.isDisabledRefusal(error) && clock.now() - start < waitTimeout {
                logger.info().log("Target disabled, checking again in \(pollInterval)s…")
                try await clock.sleep(.seconds(pollInterval))
            }
        }
    }

    private static func pollOnce(
        query: AccessibilityQuery,
        waitTimeout: TimeInterval,
        pollInterval: TimeInterval,
        transientGrace: TimeInterval,
        elementType: String?,
        allowOffscreen: Bool,
        settle: SettlePolicy,
        pick: MatchPicker?,
        logger: OffsiderLogger,
        clock: PollClock,
        treeFetcher: () async throws -> UITree
    ) async throws -> Polled<TapResolution> {
        let resolver: (UITree, Bool) async throws -> TapResolution = { tree, explain in
            let chosen: MatchPick? = await pick?(tree.roots) ?? nil
            return try AccessibilityTargetResolver.resolveTap(
                roots: tree.roots, query: query, elementType: elementType, allowOffscreen: allowOffscreen, explainFailures: explain, pick: chosen,
                front: tree.front, logger: logger
            )
        }
        let polled = try await poll(
            waitTimeout: waitTimeout,
            pollInterval: pollInterval,
            transientGrace: transientGrace,
            logger: logger,
            clock: clock,
            resolver: resolver,
            position: { resolution in UIPoint(x: resolution.point.x, y: resolution.point.y) },
            treeFetcher: treeFetcher
        )
        return try await settled(polled, policy: settle, target: { $0.target ?? $0.matched }, logger: logger, treeFetcher: treeFetcher) { tree, explain in
            do {
                return try await resolver(tree, explain)
            } catch let error as ElementResolutionError {
                // Mid-transition copies of the target: take the one nearest where it was first found.
                guard case .multipleMatches = error, let first = polled.value.matched, let centre = first.frame?.center,
                      let nearest = NodeIdentity.nearest(tree.roots.flatMap { $0.flattened() }.filter { NodeIdentity.isGuardMatch($0, first) }, to: centre) else {
                    throw error
                }
                return try AccessibilityTargetResolver.resolveTap(
                    roots: [nearest], query: query, elementType: elementType, allowOffscreen: true, explainFailures: false, logger: logger
                )
            }
        }
    }

    /// The transition guard: acts at once when the cache shows the target at rest, else waits and resolves on one more read.
    static func settled<T>(
        _ polled: Polled<T>,
        policy: SettlePolicy,
        target: (T) -> UINode?,
        logger: OffsiderLogger,
        environment: TreeCacheEnvironment = .current,
        treeFetcher: () async throws -> UITree,
        resolve: (UITree, Bool) async throws -> T
    ) async throws -> Polled<T> {
        var result = polled
        guard case .guarded(let cached) = policy else {
            result.settledBy = .actNow(.optedOut)
            return result
        }
        guard !polled.waited else {
            result.settledBy = .actNow(.alreadySettled)
            return result
        }
        guard let node = target(polled.value) else { return result }
        let record = cached.flatMap { $0.matches(appFrame: polled.tree.applicationFrame) ? $0 : nil }
        let decision = TransitionGuard.decide(target: node, record: record, now: environment.now(), keyboardShowing: TextFocus.hasKeyboard(polled.tree))
        result.settledBy = decision
        guard case .recheck(let delay) = decision else { return result }
        func read(_ delay: Duration) async throws -> UITree {
            try await Timings.measure("settle") {
                try await environment.sleep(delay)
                return try await treeFetcher()
            }
        }
        let tree = try await read(delay)
        do {
            var settled = Polled(value: try await resolve(tree, false), tree: tree, settledBy: decision)
            // A window sliding in, as an Android dialog does, moves its content between reads: act once two reads agree.
            var before = node.frame?.center
            var reads = 0
            let started = ContinuousClock.now
            while let now = target(settled.value)?.frame?.center, let last = before, abs(now.x - last.x) > TransitionGuard.frameTolerance || abs(now.y - last.y) > TransitionGuard.frameTolerance,
                  TransitionGuard.movingGap * reads < TransitionGuard.movingLimit, ContinuousClock.now - started < TransitionGuard.movingLimit {
                before = now
                reads += 1
                let next = try await read(TransitionGuard.movingGap)
                settled = Polled(value: try await resolve(next, false), tree: next, settledBy: decision)
            }
            return settled
        } catch is ElementResolutionError {
            logger.info().log("The target was not found again after waiting for the screen to settle; reading once more.")
        }
        // Never where it was first found: whatever replaced it there would take the tap.
        let last = try await read(TransitionGuard.goneGap)
        do {
            return Polled(value: try await resolve(last, true), tree: last, settledBy: decision)
        } catch let miss as ElementResolutionError {
            throw CutTreeMiss.wrapping(miss, tree: last)
        }
    }

    /// The miss in `error` when a later read could find the target, through the cut tree line.
    private static func retryableMiss(_ error: any Error) -> ElementResolutionError? {
        let miss = error as? ElementResolutionError ?? (error as? CutTreeMiss)?.miss
        return miss?.isRetryable == true ? miss : nil
    }

    /// Missing or off-screen elements retry until `waitTimeout` and then until two reads agree; transient read failures until the larger window, and at least once.
    /// `resolver` explains a miss (suggestions and candidates) only when its second argument is true, for the error finally thrown.
    private static func poll<T>(
        waitTimeout: TimeInterval,
        pollInterval: TimeInterval,
        transientGrace: TimeInterval,
        logger: OffsiderLogger,
        clock: PollClock,
        resolver: (UITree, Bool) async throws -> T,
        position: (T) -> UIPoint,
        treeFetcher: () async throws -> UITree
    ) async throws -> Polled<T> {
        let start = clock.now()
        let findDeadline = start + waitTimeout
        let transientWindow = max(waitTimeout, transientGrace)
        let transientDeadline = start + transientWindow
        var transientRetries = 0
        var waitedForElement = false
        var lastPosition: UIPoint?

        while true {
            let tree: UITree
            do {
                tree = try await treeFetcher()
            } catch where error.isTransientFailure && transientWindow > 0 && (transientRetries == 0 || clock.now() < transientDeadline) {
                transientRetries += 1
                logger.info().log("\(error.localizedDescription) Retrying in \(pollInterval)s…")
                try await clock.sleep(.seconds(pollInterval))
                continue
            }
            do {
                let polled = Polled(value: try await resolver(tree, false), tree: tree, waited: waitedForElement)
                guard waitedForElement else { return polled }
                let current = position(polled.value)
                if let lastPosition, ElementMotion.hasSettled(previous: lastPosition, current: current) { return polled }
                // Out of time before two reads agreed, so the transition guard decides.
                guard clock.now() < findDeadline else { return Polled(value: polled.value, tree: tree) }
                if lastPosition != nil { logger.info().log("Element still moving, checking again in \(pollInterval)s…") }
                lastPosition = current
                try await clock.sleep(.seconds(pollInterval))
            } catch let error as ElementResolutionError where error.isRetryable && clock.now() < findDeadline {
                waitedForElement = true
                lastPosition = nil
                let reason = error.isOffScreen ? "Element off screen" : "Element not found"
                logger.info().log("\(reason), retrying in \(pollInterval)s…")
                try await clock.sleep(.seconds(pollInterval))
            } catch ElementResolutionError.notFound {
                do {
                    return Polled(value: try await resolver(tree, true), tree: tree)
                } catch let miss as ElementResolutionError {
                    throw CutTreeMiss.wrapping(miss, tree: tree)
                }
            }
        }
    }
}
