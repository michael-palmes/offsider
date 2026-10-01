import Foundation
import OffsiderCore

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
        logger: OffsiderLogger
    ) async throws -> TapResolution {
        try await pollForResolution(
            query: query,
            waitTimeout: waitTimeout,
            pollInterval: pollInterval,
            transientGrace: transientGrace,
            elementType: elementType,
            logger: logger,
            resolver: AccessibilityTargetResolver.resolveTap
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
        logger: OffsiderLogger
    ) async throws -> AccessibilityMatch {
        try await pollForResolution(
            query: query,
            waitTimeout: waitTimeout,
            pollInterval: pollInterval,
            transientGrace: 0,
            elementType: elementType,
            logger: logger,
            resolver: AccessibilityTargetResolver.resolveElement
        ) {
            try await backend.accessibilityTree(for: device)
        }
    }

    static func pollForResolution(
        query: AccessibilityQuery,
        waitTimeout: TimeInterval,
        pollInterval: TimeInterval,
        transientGrace: TimeInterval = 0,
        elementType: String?,
        logger: OffsiderLogger,
        treeFetcher: () async throws -> UITree
    ) async throws -> TapResolution {
        try await pollForResolution(
            query: query,
            waitTimeout: waitTimeout,
            pollInterval: pollInterval,
            transientGrace: transientGrace,
            elementType: elementType,
            logger: logger,
            resolver: AccessibilityTargetResolver.resolveTap,
            treeFetcher: treeFetcher
        )
    }

    /// Missing elements retry until `waitTimeout`; transient read failures until the larger window, and at least once.
    private static func pollForResolution<T>(
        query: AccessibilityQuery,
        waitTimeout: TimeInterval,
        pollInterval: TimeInterval,
        transientGrace: TimeInterval,
        elementType: String?,
        logger: OffsiderLogger,
        resolver: ([UINode], AccessibilityQuery, String?) throws -> T,
        treeFetcher: () async throws -> UITree
    ) async throws -> T {
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
                return try resolver(tree.roots, query, elementType)
            } catch let error as ElementResolutionError where error.isNotFound && clock.now < findDeadline {
                logger.info().log("Element not found, retrying in \(pollInterval)s…")
                try await Task.sleep(for: .seconds(pollInterval))
            }
        }
    }
}
