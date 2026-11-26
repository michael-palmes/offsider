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
        var skippedBeneath: Int?
        var maskUnproven: String?
        var changed: Bool?
        var expect: String?
        var entries: Int?
        var redacted: Int?
        var prompt: String?
        var button: String?
        var fields: [RunFieldOutcome]?
        var enrolled: Bool?
    }

    /// Nil records nothing.
    let environment: EvidenceRunEnvironment?
    /// The command path, such as `screenshot` or `batch`.
    let command: String
    /// The arguments after the command path, before redaction.
    let arguments: [String]

    private var lookup: Result<ActiveRun?, any Error>?
    private var notedEndedRun = false
    private var pending: [Int: Entry] = [:]
    private var nextID = 0

    nonisolated init(environment: EvidenceRunEnvironment?, command: String, arguments: [String]) {
        self.environment = environment
        self.command = command
        self.arguments = arguments
    }

    /// Commands that record into a run when one is active (video only reads its masks; `login` only `--fill`; `alert` and `biometric` write no file).
    static let recordingCommands = ["screenshot", "logs", "batch", "record-video", "stream-video", "swipe", "drag", "app prefs", "alert", "login", "biometric"]

    static func records(_ command: String) -> Bool {
        recordingCommands.contains(command) || command.hasPrefix("run ")
    }

    /// The caller's run, found once; a run that cannot be read is an error, never no run, so no capture drops its masks.
    func run() throws -> ActiveRun? {
        guard let environment else { return nil }
        if lookup == nil, case .off = environment.override { noteRunOff(in: environment) }
        let result = lookup ?? Result { try RunRegistry.active(in: environment) }
        lookup = result
        return try result.get()
    }

    /// Once per process, so `OFFSIDER_RUN=off` never drops a capture from a run without a word; reads the records only when there are any.
    static var notedRunOff = false

    private func noteRunOff(in environment: EvidenceRunEnvironment) {
        guard !Self.notedRunOff, !["record-video", "stream-video"].contains(command) else { return }
        Self.notedRunOff = true
        guard let directory = try? environment.runsDirectory(), let names = try? FileManager.default.contentsOfDirectory(atPath: directory), !names.isEmpty,
              let record = try? RunRegistry.record(of: environment) else { return }
        Console.current.notice(Self.runOffNotice(dir: record.dir))
    }

    nonisolated static func runOffNotice(dir: String) -> Notice {
        .note(
            "OFFSIDER_RUN=off: not recording into \(TerminalText.homePath(dir)), nor applying its masks",
            agent: "OFFSIDER_RUN=off: not recording into \(dir), nor applying its masks"
        )
    }

    /// The run's masks, added to every capture's own; throws when the run cannot be read.
    func defaultMasks() throws -> MaskPlan? {
        guard let masks = try run()?.masks, !masks.isEmpty else { return nil }
        return masks.plan
    }

    /// The caller's run masks for a command that records nothing, such as `describe-ui` or `tap`, so its tree output and the
    /// tree cache honour them too; nil without a run. Costs one directory listing when no run is recorded.
    nonisolated static func ambientMasks(environment: EvidenceRunEnvironment = .live()) -> RunMasks? {
        switch environment.override {
        case .off:
            return nil
        case .folder(let path):
            return (try? RunFolder(path: path).readState())?.masks ?? .defaults
        case .none:
            guard let directory = try? environment.runsDirectory(),
                  let names = try? FileManager.default.contentsOfDirectory(atPath: directory), !names.isEmpty else { return nil }
            return (try? RunRegistry.record(of: environment))?.masks
        }
    }

    /// Starts an entry; nil when there is no run, after noting once a run whose session has exited.
    func begin(device: DeviceID?, kind: String) throws -> Token? {
        guard let environment else { return nil }
        guard try run() != nil else {
            noteEndedRun(in: environment)
            return nil
        }
        nextID += 1
        pending[nextID] = Entry(start: environment.now(), device: device?.rawValue, platform: device?.platform.rawValue, kind: kind)
        return Token(id: nextID)
    }

    /// A new session's capture would otherwise land outside the run its last session started, with no word of it.
    private func noteEndedRun(in environment: EvidenceRunEnvironment) {
        guard !notedEndedRun else { return }
        notedEndedRun = true
        guard let ended = RunRegistry.endedRun(in: environment) else { return }
        Console.current.notice(Self.endedRunNotice(dir: ended.dir, expired: ended.expired))
    }

    nonisolated static func endedRunNotice(dir: String, expired: Bool = false) -> Notice {
        let start = RunRegistry.startCommand(dir)
        let how = expired ? "expired" : "ended with its session"
        return .note(
            "Not recorded: the run in \(TerminalText.homePath(dir)) \(how)",
            agent: "The run in \(dir) \(how), so this capture is not in it; `\(start)` carries on its numbering.",
            see: start, label: "Try"
        )
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
    @discardableResult
    func finish(_ token: Token, exit: Int32, reason: String?, step: Int? = nil, line: String? = nil, ask: String? = nil) -> Bool {
        guard let environment, let entry = pending.removeValue(forKey: token.id), let run = try? run() else { return false }
        let now = environment.now()
        let manifestLine = RunManifestLine(
            n: entry.number, file: entry.file, command: command, step: step, line: line, device: entry.device, platform: entry.platform,
            time: entry.reservedAt ?? entry.start, ms: Int((now.timeIntervalSince(entry.start) * 1000).rounded()), exit: Int(exit), reason: reason,
            args: step == nil ? SelectorRedaction.redacted(arguments).map { LogRedactor.redact($0).text } : nil,
            output: entry.output, diff: entry.diff, masked: entry.masked, skippedBeneath: entry.skippedBeneath, maskUnproven: entry.maskUnproven, changed: entry.changed, expect: entry.expect, entries: entry.entries, redacted: entry.redacted,
            prompt: entry.prompt, button: entry.button, fields: entry.fields, ask: ask, enrolled: entry.enrolled
        )
        do {
            try run.folder.append(manifestLine)
            return true
        } catch {
            let message = TerminalText.line(OffsiderCommand.message(for: error), cap: TerminalText.maxErrorCharacters)
            Console.current.line(
                "Warning: could not add to \(run.folder.file(RunFolder.manifestName)): \(message)",
                person: .warning("This capture is missing from the run's manifest: \(message)")
            )
            return false
        }
    }

    /// A batch step's captures, with its number and redacted line.
    func finishPending(step: Int, line: String, exit: Int32, reason: String?) {
        for id in pending.keys.sorted() {
            finish(Token(id: id), exit: exit, reason: reason, step: step, line: line)
        }
    }

    /// Every entry still open when the command ends; true when a line was written, and the first carries `ask`.
    @discardableResult
    func finishAll(exit: Int32, reason: String?, ask: String? = nil) -> Bool {
        var wrote = false
        for id in pending.keys.sorted() {
            if finish(Token(id: id), exit: exit, reason: reason, ask: wrote ? nil : ask) { wrote = true }
        }
        return wrote
    }
}
