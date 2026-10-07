import Foundation
import OffsiderCore

/// A resolution and the tree it came from, so callers reuse that tree instead of reading another.
struct Polled<T> {
    let value: T
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
            logger: logger
        ) {
            try await backend.accessibilityTree(for: device)
        }
    }

    static func resolveElementWithPolling(
        query: AccessibilityQuery,
        on backend: any DeviceBackend,
        device: DeviceID,
        waitTimeout: TimeInterval,
        pollInterval: TimeInterval,
        elementType: String? = nil,
        allowOffscreen: Bool = false,
        settle: SettlePolicy = .off,
        logger: OffsiderLogger
    ) async throws -> Polled<AccessibilityMatch> {
        let resolver: ([UINode], Bool) throws -> AccessibilityMatch = { roots, explain in
            try AccessibilityTargetResolver.resolveElement(
                roots: roots, query: query, elementType: elementType, allowOffscreen: allowOffscreen, explainFailures: explain, logger: logger
            )
        }
        let fetch: () async throws -> UITree = { try await backend.accessibilityTree(for: device) }
        let polled = try await poll(
            waitTimeout: waitTimeout,
            pollInterval: pollInterval,
            transientGrace: 0,
            logger: logger,
            clock: .live,
            resolver: resolver,
            position: { match in match.element.frame?.center ?? UIPoint(x: 0, y: 0) },
            treeFetcher: fetch
        )
        return try await settled(polled, policy: settle, target: \.element, logger: logger, treeFetcher: fetch) { roots in
            try resolver(roots, false)
        }
    }

    static func pollForResolution(
        query: AccessibilityQuery,
        waitTimeout: TimeInterval,
        pollInterval: TimeInterval,
        transientGrace: TimeInterval = 0,
        elementType: String?,
        allowOffscreen: Bool = false,
        settle: SettlePolicy = .off,
        pick: MatchPicker? = nil,
        logger: OffsiderLogger,
        clock: PollClock = .live,
        treeFetcher: () async throws -> UITree
    ) async throws -> Polled<TapResolution> {
        let resolver: ([UINode], Bool) async throws -> TapResolution = { roots, explain in
            let chosen: MatchPick? = await pick?(roots) ?? nil
            return try AccessibilityTargetResolver.resolveTap(
                roots: roots, query: query, elementType: elementType, allowOffscreen: allowOffscreen, explainFailures: explain, pick: chosen, logger: logger
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
        return try await settled(polled, policy: settle, target: { $0.target ?? $0.matched }, logger: logger, treeFetcher: treeFetcher) { roots in
            do {
                return try await resolver(roots, false)
            } catch ElementResolutionError.multipleMatches {
                // Mid-transition copies of the target: take the one nearest where it was first found.
                guard let first = polled.value.matched, let centre = first.frame?.center,
                      let nearest = NodeIdentity.nearest(roots.flatMap { $0.flattened() }.filter { NodeIdentity.isGuardMatch($0, first) }, to: centre) else {
                    throw ElementResolutionError.notFound(kind: query.kind, value: query.rawValue)
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
        resolve: ([UINode]) async throws -> T
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
        let decision = TransitionGuard.decide(target: node, record: record, now: environment.now())
        result.settledBy = decision
        guard case .recheck(let delay) = decision else { return result }
        let tree = try await Timings.measure("settle") {
            try await environment.sleep(delay)
            return try await treeFetcher()
        }
        do {
            return Polled(value: try await resolve(tree.roots), tree: tree, settledBy: decision)
        } catch {
            logger.info().log("The target was not found again after waiting for the screen to settle; acting where it was first found.")
            return result
        }
    }

    /// Missing or off-screen elements retry until `waitTimeout` and then until two reads agree; transient read failures until the larger window, and at least once.
    /// `resolver` explains a miss (suggestions and candidates) only when its second argument is true, for the error finally thrown.
    private static func poll<T>(
        waitTimeout: TimeInterval,
        pollInterval: TimeInterval,
        transientGrace: TimeInterval,
        logger: OffsiderLogger,
        clock: PollClock,
        resolver: ([UINode], Bool) async throws -> T,
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
                let polled = Polled(value: try await resolver(tree.roots, false), tree: tree, waited: waitedForElement)
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
                return Polled(value: try await resolver(tree.roots, true), tree: tree)
            }
        }
    }
}
