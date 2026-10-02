import ArgumentParser
import Foundation
import OffsiderCore

enum AXCachePolicy: String, CaseIterable, ExpressibleByArgument {
    /// Reuses the latest tree until a step sends input or sleeps.
    case perBatch
    case perStep
    /// An alias of `perStep`, kept for existing scripts.
    case none
}

enum TypeSubmissionMode: String, CaseIterable, ExpressibleByArgument {
    case chunked
    case composite
}

@MainActor
final class BatchContext {
    let backend: any DeviceBackend
    let device: DeviceID
    let axCachePolicy: AXCachePolicy
    let typeSubmissionMode: TypeSubmissionMode
    let typeChunkSize: Int
    let tapStyle: TapStyle
    let waitTimeout: TimeInterval
    let pollInterval: TimeInterval

    private var cachedTree: UITree?

    init(
        backend: any DeviceBackend,
        device: DeviceID,
        axCachePolicy: AXCachePolicy,
        typeSubmissionMode: TypeSubmissionMode,
        typeChunkSize: Int,
        tapStyle: TapStyle = .automatic,
        waitTimeout: TimeInterval = 0,
        pollInterval: TimeInterval = 0.25
    ) {
        self.backend = backend
        self.device = device
        self.axCachePolicy = axCachePolicy
        self.typeSubmissionMode = typeSubmissionMode
        self.typeChunkSize = typeChunkSize
        self.tapStyle = tapStyle
        self.waitTimeout = waitTimeout
        self.pollInterval = pollInterval
    }

    func accessibilityTree(forceRefresh: Bool = false) async throws -> UITree {
        switch axCachePolicy {
        case .perStep, .none:
            return try await backend.accessibilityTree(for: device)
        case .perBatch:
            if !forceRefresh, let cachedTree {
                return cachedTree
            }
            let tree = try await backend.accessibilityTree(for: device)
            cachedTree = tree
            return tree
        }
    }

    /// Reads for one polling step: the first read may reuse the cache, later reads are fresh and become the cache.
    func pollingTreeSource() -> Wait.TreeSource {
        var isFirstFetch = true
        return { [self] in
            let forceRefresh = !isFirstFetch
            isFirstFetch = false
            return try await accessibilityTree(forceRefresh: forceRefresh)
        }
    }

    /// Drops the cached tree; a step that sent input or slept may have changed the screen.
    func invalidateTree() {
        cachedTree = nil
    }

    /// Caches a tree a step read itself, so the next selector step can reuse it under `perBatch`.
    func remember(_ tree: UITree) {
        guard axCachePolicy == .perBatch else { return }
        cachedTree = tree
    }
}

