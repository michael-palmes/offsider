import Foundation
import OffsiderCore

/// Records one command's captures into the caller's evidence run: numbered files and one manifest line each.
/// Bound per command in `main.swift`; the default records nothing, so in-process tests never touch a developer's run.
@MainActor
final class EvidenceRecorder {
    @TaskLocal static var current = EvidenceRecorder(environment: nil, command: "", arguments: [])

    struct Token: Hashable {
        fileprivate let id: Int
    }

    /// What a capture has done so far, for its manifest line.
    struct Entry {
        let start: Date
        /// When the file was reserved, which its name carries; the manifest's `time` then uses it too.
        var reservedAt: Date?
        let device: String?
        let platform: String?
        let kind: String
        var number: Int?
        var file: String?
        var output: String?
        var diff: String?
        var masked: Int?
        var changed: Bool?
        var entries: Int?
        var redacted: Int?
    }

    /// Nil records nothing.
    let environment: EvidenceRunEnvironment?
    /// The command path, such as `screenshot` or `batch`.
    let command: String
    /// The arguments after the command path, before redaction.
    let arguments: [String]

    private var resolved = false
    private var cachedRun: ActiveRun?
    private var pending: [Int: Entry] = [:]
    private var nextID = 0

    nonisolated init(environment: EvidenceRunEnvironment?, command: String, arguments: [String]) {
        self.environment = environment
        self.command = command
        self.arguments = arguments
    }

    /// The commands that look for a run.
    static func records(_ command: String) -> Bool {
        ["screenshot", "logs", "batch"].contains(command) || command.hasPrefix("run ")
    }

    /// The caller's run, found once; a run that cannot be found is no run, but an `OFFSIDER_RUN` folder that cannot be used is an error.
    func run() throws -> ActiveRun? {
        guard let environment else { return nil }
        if !resolved {
            resolved = true
            if case .folder = environment.override {
                cachedRun = try RunRegistry.active(in: environment)
            } else {
                cachedRun = try? RunRegistry.active(in: environment)
            }
        }
        return cachedRun
    }

    /// The run's masks, added to every capture's own.
    var defaultMasks: MaskPlan? {
        guard let masks = (try? run())??.masks, !masks.isEmpty else { return nil }
        return masks.plan
    }

    /// Starts an entry; nil when there is no run.
    func begin(device: DeviceID?, kind: String) throws -> Token? {
        guard let environment, try run() != nil else { return nil }
        nextID += 1
        pending[nextID] = Entry(start: environment.now(), device: device?.rawValue, platform: device?.platform.rawValue, kind: kind)
        return Token(id: nextID)
    }

    /// Takes the entry's number and returns the path of its file in the run folder, such as `/run/004-screenshot-14.03.22.png`.
    func reserveFile(_ token: Token, extension pathExtension: String) throws -> String {
        guard let environment, let run = try run(), var entry = pending[token.id] else {
            throw RunRegistry.unavailable("No run is active for this capture.")
        }
        let now = environment.now()
        let number = try run.folder.reserveNumber(now: now)
        let name = RunFolder.fileName(number: number, kind: entry.kind, at: now, extension: pathExtension, timeZone: environment.timeZone)
        entry.number = number
        entry.file = name
        entry.reservedAt = now
        pending[token.id] = entry
        return run.folder.file(name)
    }

    /// The diff beside the entry's file: `004-screenshot-14.03.22-diff.png`.
    func diffPath(_ token: Token) throws -> String? {
        guard let run = try run(), var entry = pending[token.id], let file = entry.file else { return nil }
        let name = (file as NSString).deletingPathExtension + "-diff.png"
        entry.diff = name
        pending[token.id] = entry
        return run.folder.file(name)
    }

    func update(_ token: Token?, _ change: (inout Entry) -> Void) {
        guard let token, var entry = pending[token.id] else { return }
        change(&entry)
        pending[token.id] = entry
    }

    /// Writes the entry's manifest line; a manifest that cannot be written is a warning, since the capture itself succeeded or failed already.
    func finish(_ token: Token, exit: Int32, reason: String?, step: Int? = nil, line: String? = nil) {
        guard let environment, let entry = pending.removeValue(forKey: token.id), let run = try? run() else { return }
        let now = environment.now()
        let manifestLine = RunManifestLine(
            n: entry.number, file: entry.file, command: command, step: step, line: line, device: entry.device, platform: entry.platform,
            time: entry.reservedAt ?? entry.start, ms: Int((now.timeIntervalSince(entry.start) * 1000).rounded()), exit: Int(exit), reason: reason,
            args: step == nil ? arguments.map { LogRedactor.redact($0).text } : nil,
            output: entry.output, diff: entry.diff, masked: entry.masked, changed: entry.changed, entries: entry.entries, redacted: entry.redacted
        )
        do {
            try run.folder.append(manifestLine)
        } catch {
            FileHandle.standardError.write(Data("Warning: could not add to \(run.folder.file(RunFolder.manifestName)): \(OffsiderCommand.message(for: error))\n".utf8))
        }
    }

    /// A batch step's captures, with its number and redacted line.
    func finishPending(step: Int, line: String, exit: Int32, reason: String?) {
        for id in pending.keys.sorted() {
            finish(Token(id: id), exit: exit, reason: reason, step: step, line: line)
        }
    }

    /// Every entry still open when the command ends.
    func finishAll(exit: Int32, reason: String?) {
        for id in pending.keys.sorted() {
            finish(Token(id: id), exit: exit, reason: reason)
        }
    }
}
