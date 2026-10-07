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
    /// Armed for the batch's setup, then around each wait and assert step as the standalone commands arm it.
    let watchdog: DeviceWatchdog
    /// `batch --mask-secure`: every screenshot step masks secure fields, reusing the cached tree.
    let maskSecure: Bool
    /// `batch --no-settle`: tap steps skip the transition guard.
    let noSettle: Bool
    /// The device's cached record from before the batch, for the guard until a step sends input.
    let cachedRecord: TreeCacheRecord?

    private var cachedTree: UITree?
    /// The latest tree any step read, kept when the cache is dropped so the guard can compare against it.
    private var lastTree: UITree?
    private var lastInputAt: Date?

    init(
        backend: any DeviceBackend,
        device: DeviceID,
        axCachePolicy: AXCachePolicy,
        typeSubmissionMode: TypeSubmissionMode,
        typeChunkSize: Int,
        tapStyle: TapStyle = .automatic,
        waitTimeout: TimeInterval = 0,
        pollInterval: TimeInterval = 0.25,
        watchdog: DeviceWatchdog = DeviceWatchdog(),
        maskSecure: Bool = false,
        noSettle: Bool = false,
        cachedRecord: TreeCacheRecord? = nil
    ) {
        self.backend = backend
        self.device = device
        self.axCachePolicy = axCachePolicy
        self.typeSubmissionMode = typeSubmissionMode
        self.typeChunkSize = typeChunkSize
        self.tapStyle = tapStyle
        self.waitTimeout = waitTimeout
        self.pollInterval = pollInterval
        self.watchdog = watchdog
        self.maskSecure = maskSecure
        self.noSettle = noSettle
        self.cachedRecord = cachedRecord
    }

    func accessibilityTree(forceRefresh: Bool = false) async throws -> UITree {
        switch axCachePolicy {
        case .perStep, .none:
            let tree = try await backend.accessibilityTree(for: device)
            lastTree = tree
            return tree
        case .perBatch:
            if !forceRefresh, let cachedTree {
                return cachedTree
            }
            let tree = try await backend.accessibilityTree(for: device)
            cachedTree = tree
            lastTree = tree
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
    func invalidateTree(sentInput: Bool = false) {
        cachedTree = nil
        if sentInput {
            lastInputAt = TreeCacheEnvironment.current.now()
        }
    }

    /// A step's `--app` stays for later steps, as for later commands; trees read for another app are dropped.
    func applyApp(of step: Any) {
        guard let option = (step as? AppTargeting)?.appOption, option.apply(to: route) else { return }
        cachedTree = nil
        lastTree = nil
    }

    /// The guard's baseline: this batch's latest tree, with its last input or else the disk record's.
    func settlePolicy(stepOptedOut: Bool) -> SettlePolicy {
        guard !noSettle, !stepOptedOut else { return .off }
        guard let lastTree else { return .guarded(record: lastInputAt == nil ? cachedRecord : record(lastInputAt: lastInputAt, tree: nil)) }
        if let lastInputAt {
            return .guarded(record: record(lastInputAt: lastInputAt, tree: lastTree))
        }
        if let cachedRecord {
            return .guarded(record: record(lastInputAt: cachedRecord.lastInputAt, tree: lastTree))
        }
        return .guarded(record: record(lastInputAt: TreeCacheEnvironment.current.now(), tree: lastTree))
    }

    private func record(lastInputAt: Date?, tree: UITree?) -> TreeCacheRecord {
        TreeCacheRecord(
            platform: device.platform,
            device: device.rawValue,
            command: "batch",
            writtenAt: TreeCacheEnvironment.current.now(),
            lastInputAt: lastInputAt,
            treeRole: tree == nil ? nil : .read,
            appFrame: tree?.applicationFrame,
            roots: tree?.roots
        )
    }
}

