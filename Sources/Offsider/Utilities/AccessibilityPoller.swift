import Foundation
import OffsiderCore

/// A resolution and the tree it came from, so callers reuse that tree instead of reading another.
struct Polled<T> {
    let value: T
    let tree: UITree
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
        logger: OffsiderLogger
    ) async throws -> Polled<TapResolution> {
        try await pollForResolution(
            query: query,
            waitTimeout: waitTimeout,
            pollInterval: pollInterval,
            transientGrace: transientGrace,
            elementType: elementType,
            allowOffscreen: allowOffscreen,
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
        logger: OffsiderLogger
    ) async throws -> Polled<AccessibilityMatch> {
        try await poll(
            waitTimeout: waitTimeout,
            pollInterval: pollInterval,
            transientGrace: 0,
            logger: logger,
            clock: .live,
            resolver: { roots in
                try AccessibilityTargetResolver.resolveElement(
                    roots: roots, query: query, elementType: elementType, allowOffscreen: allowOffscreen, logger: logger
                )
            },
            position: { match in match.element.frame?.center ?? UIPoint(x: 0, y: 0) },
            treeFetcher: { try await backend.accessibilityTree(for: device) }
        )
    }

    static func pollForResolution(
        query: AccessibilityQuery,
        waitTimeout: TimeInterval,
        pollInterval: TimeInterval,
        transientGrace: TimeInterval = 0,
        elementType: String?,
        allowOffscreen: Bool = false,
        logger: OffsiderLogger,
        clock: PollClock = .live,
        treeFetcher: () async throws -> UITree
    ) async throws -> Polled<TapResolution> {
        try await poll(
            waitTimeout: waitTimeout,
            pollInterval: pollInterval,
            transientGrace: transientGrace,
            logger: logger,
            clock: clock,
            resolver: { roots in
                try AccessibilityTargetResolver.resolveTap(
                    roots: roots, query: query, elementType: elementType, allowOffscreen: allowOffscreen, logger: logger
                )
            },
            position: { resolution in UIPoint(x: resolution.point.x, y: resolution.point.y) },
            treeFetcher: treeFetcher
        )
    }

    /// Missing or off-screen elements retry until `waitTimeout` and then until two reads agree; transient read failures until the larger window, and at least once.
    private static func poll<T>(
        waitTimeout: TimeInterval,
        pollInterval: TimeInterval,
        transientGrace: TimeInterval,
        logger: OffsiderLogger,
        clock: PollClock,
        resolver: ([UINode]) throws -> T,
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
                let polled = Polled(value: try resolver(tree.roots), tree: tree)
                guard waitedForElement else { return polled }
                let current = position(polled.value)
                if let lastPosition, ElementMotion.hasSettled(previous: lastPosition, current: current) { return polled }
                guard clock.now() < findDeadline else { return polled }
                if lastPosition != nil { logger.info().log("Element still moving, checking again in \(pollInterval)s…") }
                lastPosition = current
                try await clock.sleep(.seconds(pollInterval))
            } catch let error as ElementResolutionError where error.isRetryable && clock.now() < findDeadline {
                waitedForElement = true
                lastPosition = nil
                let reason = error.isOffScreen ? "Element off screen" : "Element not found"
                logger.info().log("\(reason), retrying in \(pollInterval)s…")
                try await clock.sleep(.seconds(pollInterval))
            }
        }
    }
}
