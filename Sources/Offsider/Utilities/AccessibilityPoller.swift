import Foundation
import OffsiderCore

@MainActor
struct AccessibilityPoller {
    static func resolveWithPolling(
        query: AccessibilityQuery,
        on backend: any DeviceBackend,
        device: DeviceID,
        waitTimeout: TimeInterval,
        pollInterval: TimeInterval,
        elementType: String? = nil,
        logger: OffsiderLogger
    ) async throws -> TapResolution {
        try await pollForResolution(
            query: query,
            waitTimeout: waitTimeout,
            pollInterval: pollInterval,
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
        elementType: String?,
        logger: OffsiderLogger,
        treeFetcher: () async throws -> UITree
    ) async throws -> TapResolution {
        try await pollForResolution(
            query: query,
            waitTimeout: waitTimeout,
            pollInterval: pollInterval,
            elementType: elementType,
            logger: logger,
            resolver: AccessibilityTargetResolver.resolveTap,
            treeFetcher: treeFetcher
        )
    }

    private static func pollForResolution<T>(
        query: AccessibilityQuery,
        waitTimeout: TimeInterval,
        pollInterval: TimeInterval,
        elementType: String?,
        logger: OffsiderLogger,
        resolver: ([UINode], AccessibilityQuery, String?) throws -> T,
        treeFetcher: () async throws -> UITree
    ) async throws -> T {
        let tree = try await treeFetcher()
        do {
            return try resolver(tree.roots, query, elementType)
        } catch let error as ElementResolutionError where error.isNotFound && waitTimeout > 0 {
            let clock = ContinuousClock()
            let deadline = clock.now + .seconds(waitTimeout)

            var lastError = error
            while clock.now < deadline {
                logger.info().log("Element not found, retrying in \(pollInterval)s…")
                try await Task.sleep(for: .seconds(pollInterval))

                let freshTree = try await treeFetcher()
                do {
                    return try resolver(freshTree.roots, query, elementType)
                } catch let retryError as ElementResolutionError where retryError.isNotFound {
                    lastError = retryError
                    continue
                }
            }

            throw lastError
        }
    }
}
