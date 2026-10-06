import Darwin
import Foundation
import OffsiderCore

/// Where run records live, which processes exist and what time it is; a test binds its own.
struct EvidenceRunEnvironment: Sendable {
    static let variable = "OFFSIDER_RUN"

    enum Override: Equatable {
        case none
        case off
        case folder(String)
    }

    var variables: [String: String]
    var runsDirectory: @Sendable () throws -> String
    var processes: ProcessTable
    var selfPID: Int32
    var parentPID: Int32
    var now: @Sendable () -> Date
    var timeZone: TimeZone

    static func live() -> EvidenceRunEnvironment {
        EvidenceRunEnvironment(
            variables: ProcessInfo.processInfo.environment,
            runsDirectory: { try OffsiderPrivateDirectory.ensureSubdirectory(OffsiderPrivateDirectory.runsDirectoryName) },
            processes: .live,
            selfPID: getpid(),
            parentPID: getppid(),
            now: { Date() },
            timeZone: .current
        )
    }

    /// `OFFSIDER_RUN=off` records nothing; `OFFSIDER_RUN=<dir>` records into that folder whatever the session.
    var override: Override {
        guard let value = variables[Self.variable]?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return .none }
        if value.lowercased() == "off" { return .off }
        return .folder(RunRegistry.absolute(value))
    }
}

/// The run a command records into: its folder and the masks it applies by default.
struct ActiveRun: Equatable {
    let folder: RunFolder
    let masks: RunMasks
    /// Nil when `OFFSIDER_RUN=<dir>` named the folder.
    let record: RunRecord?
}

/// Starting, finding, stopping and listing runs. A command belongs to the run whose owner (pid and start time) is in its own ancestry.
enum RunRegistry {
    static func absolute(_ path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        let joined = expanded.hasPrefix("/") ? expanded : (FileManager.default.currentDirectoryPath as NSString).appendingPathComponent(expanded)
        return URL(fileURLWithPath: joined).standardizedFileURL.path
    }

    static func unavailable(_ message: String) -> CLIError {
        CLIError(errorDescription: message, reason: .runUnavailable)
    }

    /// The caller's run: the `OFFSIDER_RUN` folder, else the record of the nearest ancestor that started one.
    static func active(in environment: EvidenceRunEnvironment) throws -> ActiveRun? {
        switch environment.override {
        case .off:
            return nil
        case .folder(let path):
            let folder: RunFolder
            do {
                folder = try RunFolder.prepare(path).folder
            } catch {
                throw unavailable("OFFSIDER_RUN names \(path), which cannot be used as a run folder: \(OffsiderCommand.message(for: error)).")
            }
            return ActiveRun(folder: folder, masks: (try? folder.readState())??.masks ?? RunMasks(), record: nil)
        case .none:
            guard let found = try record(of: environment) else { return nil }
            return ActiveRun(folder: RunFolder(path: found.dir), masks: found.masks, record: found)
        }
    }

    /// The record whose owner is the caller or one of its ancestors, nearest first.
    static func record(of environment: EvidenceRunEnvironment) throws -> RunRecord? {
        let directory = try environment.runsDirectory()
        for ancestor in ProcessAncestry.ancestors(of: environment.selfPID, in: environment.processes) {
            let name = RunRecord.fileName(for: ancestor)
            if let data = try? OffsiderPrivateDirectory.readOwnedFile(named: name, in: directory, maxBytes: RunRecord.maximumBytes),
               let record = try? RunRecord(data: data), record.owner == ancestor {
                return record
            }
        }
        return nil
    }

    struct Started: Equatable {
        let folder: RunFolder
        let state: RunState
        /// True when the folder held a stopped run whose numbering continues.
        let continued: Bool
        /// True when this caller's run already writes to the folder, so only new masks were added.
        let unchanged: Bool
        /// True when the existing folder's group or others can write to it.
        var writableByOthers = false
        /// True when `unchanged` and this start added masks the run did not have.
        var addedMasks = false
    }

    static func start(_ path: String, label: String?, masks: RunMasks, in environment: EvidenceRunEnvironment) throws -> Started {
        let dir = absolute(path)
        var owner: ProcessIdentity?
        switch environment.override {
        case .off:
            throw unavailable("OFFSIDER_RUN=off turns evidence runs off in this shell. Unset it to start a run.")
        case .folder(let named):
            guard named == dir else {
                throw CLIError(errorDescription: "OFFSIDER_RUN names \(named), so this shell records there. Start the run in that folder, or unset OFFSIDER_RUN.", reason: .runActive)
            }
        case .none:
            _ = try endStale(in: environment)
            if let existing = try record(of: environment) {
                guard existing.dir == dir else {
                    throw CLIError(
                        errorDescription: "A run is already active in \(existing.dir) for this session. Run `offsider run stop` first, then start the new one.",
                        reason: .runActive, hint: "offsider run stop"
                    )
                }
                return try addMasks(masks, to: existing, in: environment)
            }
            guard let found = ProcessAncestry.owner(from: environment.parentPID, in: environment.processes) else {
                throw unavailable("Could not find the session that runs this command, so a run cannot be tied to it. Set OFFSIDER_RUN=<dir> instead.")
            }
            owner = found
        }

        let prepared: RunFolder.Prepared
        do {
            prepared = try RunFolder.prepare(dir)
        } catch {
            throw unavailable("Could not use \(dir) as a run folder: \(OffsiderCommand.message(for: error)).")
        }
        let folder = prepared.folder
        let now = environment.now()
        var addedMasks = false
        let (state, continued, unchanged) = try folder.locked { () throws -> (RunState, Bool, Bool) in
            if var state = try folder.readState() {
                if state.stoppedAt == nil, owner == nil {
                    let merged = state.masks.union(masks)
                    if merged != state.masks {
                        state.masks = merged
                        try folder.writeState(state)
                        addedMasks = true
                    }
                    return (state, false, true)
                }
                state.stoppedAt = nil
                state.endedBy = nil
                state.label = label ?? state.label
                state.masks = masks
                try folder.writeState(state)
                return (state, true, false)
            }
            let state = RunState(label: label, startedAt: now, masks: masks)
            try folder.writeState(state)
            return (state, false, false)
        }
        if let owner {
            let record = RunRecord(dir: dir, label: state.label, startedAt: now, masks: masks, owner: owner)
            try OffsiderPrivateDirectory.writeAtomically(try record.encoded(), named: RunRecord.fileName(for: owner), in: try environment.runsDirectory())
        }
        return Started(folder: folder, state: state, continued: continued, unchanged: unchanged, writableByOthers: prepared.writableByOthers, addedMasks: addedMasks)
    }

    /// `run start` on the session's active folder adds new masks to its record and `run.json` under the folder lock, and never removes one.
    static func addMasks(_ masks: RunMasks, to existing: RunRecord, in environment: EvidenceRunEnvironment) throws -> Started {
        let folder = RunFolder(path: existing.dir)
        guard existing.masks.union(masks) != existing.masks else {
            var state = try folder.readState() ?? RunState(label: existing.label, startedAt: existing.startedAt, masks: existing.masks)
            state.masks = existing.masks
            return Started(folder: folder, state: state, continued: false, unchanged: true)
        }
        let state: RunState
        do {
            state = try folder.locked {
                let current = try record(of: environment).flatMap { $0.dir == existing.dir ? $0 : nil } ?? existing
                var state = try folder.readState() ?? RunState(label: current.label, startedAt: current.startedAt, masks: current.masks)
                var updated = current
                updated.masks = current.masks.union(state.masks).union(masks)
                state.masks = updated.masks
                try folder.writeState(state)
                try OffsiderPrivateDirectory.writeAtomically(try updated.encoded(), named: RunRecord.fileName(for: updated.owner), in: try environment.runsDirectory())
                return state
            }
        } catch {
            throw unavailable("Could not add masks to the run in \(existing.dir): \(OffsiderCommand.message(for: error)).")
        }
        return Started(folder: folder, state: state, continued: false, unchanged: true, addedMasks: true)
    }

    /// Ends the caller's run and returns its timeline; nil when none is active.
    static func stop(in environment: EvidenceRunEnvironment) throws -> RunTimeline? {
        let folder: RunFolder
        switch environment.override {
        case .off:
            return nil
        case .folder(let path):
            folder = RunFolder(path: path)
            guard (try? folder.readState()) ?? nil != nil else { return nil }
        case .none:
            guard let record = try record(of: environment) else { return nil }
            OffsiderPrivateDirectory.removeFile(named: RunRecord.fileName(for: record.owner), in: try environment.runsDirectory())
            folder = RunFolder(path: record.dir)
        }
        let state = try end(folder, by: "run-stop", at: environment.now())
        let lines = folder.manifest()
        return RunTimeline(dir: folder.path, state: state, entries: lines, unrecorded: folder.unrecorded(given: lines))
    }

    /// Sets `stoppedAt` and `endedBy` unless the run already ended.
    @discardableResult
    static func end(_ folder: RunFolder, by reason: String, at now: Date) throws -> RunState {
        try folder.locked {
            guard var state = try folder.readState() else { return RunState(label: nil, startedAt: now, stoppedAt: now, endedBy: reason) }
            if state.stoppedAt == nil {
                state.stoppedAt = now
                state.endedBy = reason
                try folder.writeState(state)
            }
            return state
        }
    }

    /// Records whose session has exited are deleted and their folders marked `owner-exited`.
    static func endStale(in environment: EvidenceRunEnvironment) throws -> [RunStatusEntry] {
        var ended: [RunStatusEntry] = []
        for record in try allRecords(in: environment) where !environment.processes.isAlive(record.owner) {
            OffsiderPrivateDirectory.removeFile(named: RunRecord.fileName(for: record.owner), in: try environment.runsDirectory())
            let folder = RunFolder(path: record.dir)
            try? end(folder, by: "owner-exited", at: environment.now())
            ended.append(RunStatusEntry(dir: record.dir, label: record.label, startedAt: record.startedAt, owner: record.owner, files: files(in: folder), endedBy: "owner-exited"))
        }
        return ended
    }

    static func allRecords(in environment: EvidenceRunEnvironment) throws -> [RunRecord] {
        let directory = try environment.runsDirectory()
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
        return names.filter { $0.hasSuffix(".json") }.sorted().compactMap { name in
            (try? OffsiderPrivateDirectory.readOwnedFile(named: name, in: directory, maxBytes: RunRecord.maximumBytes)).flatMap { $0 }.flatMap { try? RunRecord(data: $0) }
        }
    }

    /// The caller's run, or with `all` every live run of this user, after ending stale ones.
    static func status(all: Bool, in environment: EvidenceRunEnvironment) throws -> (runs: [RunStatusEntry], ended: [RunStatusEntry]) {
        if case .off = environment.override { return ([], []) }
        let ended = try endStale(in: environment)
        var runs: [RunStatusEntry] = []
        if case .folder(let path) = environment.override, let state = (try? RunFolder(path: path).readState()) ?? nil, state.stoppedAt == nil {
            runs.append(RunStatusEntry(dir: path, label: state.label, startedAt: state.startedAt, owner: nil, files: files(in: RunFolder(path: path))))
        }
        let records = all ? try allRecords(in: environment) : (try record(of: environment)).map { [$0] } ?? []
        runs += records.map { RunStatusEntry(dir: $0.dir, label: $0.label, startedAt: $0.startedAt, owner: $0.owner, files: files(in: RunFolder(path: $0.dir))) }
        return (runs, ended)
    }

    static func files(in folder: RunFolder) -> Int {
        folder.manifest().filter { $0.file != nil }.count
    }
}
