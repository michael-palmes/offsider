import Foundation
import OffsiderCore

/// `offsider.mask.json`, found from the working directory up to the repository root and read at most once per process.
enum MaskConfigs {
    struct Loaded: Equatable, Sendable {
        let config: MaskConfig
        let path: String
    }

    /// A test binds its own file, or none.
    @TaskLocal static var source: @Sendable () throws -> Loaded? = { try Memo.shared.value() }

    /// The file's masks, or nil when there is none; a file that cannot be used stops the command naming it and its line.
    static func current() throws -> Loaded? {
        try source()
    }

    /// Reads `offsider.mask.json` from `directory` upwards; nil when none is found before the repository root.
    static func load(from directory: String) throws -> Loaded? {
        let found: ProjectGuide.Found
        do {
            found = try ProjectGuide.locate(fileName: MaskConfig.fileName, from: directory)
        } catch let failure as ProjectGuide.Failure {
            switch failure {
            case .notFound, .missingPath:
                return nil
            case .unreadable(let path, let detail):
                throw CLIError(errorDescription: "Could not read \(path): \(detail). Fix the file, or move it aside.", reason: .usage)
            }
        }
        do {
            return Loaded(config: try MaskConfig.parse(Data(found.text.utf8), path: found.path), path: found.path)
        } catch let error as MaskConfigError {
            throw CLIError(errorDescription: "\(error.message) Fix the file, or move it aside.", reason: .usage)
        }
    }

    private final class Memo: @unchecked Sendable {
        static let shared = Memo()
        private let lock = NSLock()
        private var result: Result<Loaded?, any Error>?

        func value() throws -> Loaded? {
            lock.lock()
            defer { lock.unlock() }
            if let result { return try result.get() }
            let loaded = Result { try MaskConfigs.load(from: FileManager.default.currentDirectoryPath) }
            result = loaded
            return try loaded.get()
        }
    }
}

/// The masks every capture and tree of this command honours beyond its own flags: `offsider.mask.json` and the evidence run's.
@MainActor
enum AmbientMasks {
    /// The run's masks: the recorder's when this command records, else the caller's run found from its process ancestry.
    static func runPlan(recorder: EvidenceRecorder? = nil) -> MaskPlan? {
        let recorder = recorder ?? .current
        if recorder.environment != nil { return recorder.defaultMasks }
        guard let masks = EvidenceRecorder.ambientMasks(), !masks.isEmpty else { return nil }
        return masks.plan
    }

    /// The config's and the run's masks for the values a tree shows, with the device's revealed password fields.
    static func treeMask(revealed: RevealedSecrets? = nil) throws -> TreeValueMask {
        var plan = try MaskConfigs.current()?.config.plan ?? .none
        if let run = runPlan() { plan = plan.union(run) }
        do {
            return try TreeValueMask(plan: plan, revealed: revealed)
        } catch let error as MaskPatternError {
            throw CLIError(errorDescription: error.description, reason: .usage)
        }
    }
}
