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
            resolver: { roots in
                try AccessibilityTargetResolver.resolveElement(
                    roots: roots, query: query, elementType: elementType, allowOffscreen: allowOffscreen, logger: logger
                )
            },
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
        treeFetcher: () async throws -> UITree
    ) async throws -> Polled<TapResolution> {
        try await poll(
            waitTimeout: waitTimeout,
            pollInterval: pollInterval,
            transientGrace: transientGrace,
            logger: logger,
            resolver: { roots in
                try AccessibilityTargetResolver.resolveTap(
                    roots: roots, query: query, elementType: elementType, allowOffscreen: allowOffscreen, logger: logger
                )
            },
            treeFetcher: treeFetcher
        )
    }

    /// Missing or off-screen elements retry until `waitTimeout`; transient read failures until the larger window, and at least once.
    private static func poll<T>(
        waitTimeout: TimeInterval,
        pollInterval: TimeInterval,
        transientGrace: TimeInterval,
        logger: OffsiderLogger,
        resolver: ([UINode]) throws -> T,
        treeFetcher: () async throws -> UITree
    ) async throws -> Polled<T> {
        let clock = ContinuousClock()
        let start = clock.now
        let findDeadline = start + .seconds(waitTimeout)
        let transientWindow = max(waitTimeout, transientGrace)
        let transientDeadline = start + .seconds(transientWindow)
        var transientRetries = 0

        while true {
            let tree: UITree
            do {
                tree = try await treeFetcher()
            } catch where error.isTransientFailure && transientWindow > 0 && (transientRetries == 0 || clock.now < transientDeadline) {
                transientRetries += 1
                logger.info().log("\(error.localizedDescription) Retrying in \(pollInterval)s…")
                try await Task.sleep(for: .seconds(pollInterval))
                continue
            }
            do {
                return Polled(value: try resolver(tree.roots), tree: tree)
            } catch let error as ElementResolutionError where error.isRetryable && clock.now < findDeadline {
                let reason = error.isOffScreen ? "Element off screen" : "Element not found"
                logger.info().log("\(reason), retrying in \(pollInterval)s…")
                try await Task.sleep(for: .seconds(pollInterval))
            }
        }
    }
}
