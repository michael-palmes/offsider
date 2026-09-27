import ArgumentParser
import Foundation
import OffsiderCore

enum AXCachePolicy: String, CaseIterable, ExpressibleByArgument {
    case perBatch
    case perStep
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
        case .none:
            return try await backend.accessibilityTree(for: device)
        case .perStep:
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
}

