import ArgumentParser
import Foundation
import OffsiderCore

struct RunCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run",
        abstract: "Number this session's screenshots and logs into one folder with a manifest, for a report",
        discussion: """
        After `run start <dir>`, every screenshot, logs and batch screenshot step from this session (the agent or \
        terminal that ran `run start`, found through the process's parents) is also written to <dir> as \
        NNN-<command>-<HH.MM.SS>.<ext>, and manifest.ndjson gets one line per capture, failures included. \
        `run stop --summary` ends the run and prints its timeline. Masks given to `run start` apply to every capture \
        in the run, on top of the capture's own; `run start` again on the active folder adds masks and never removes \
        one. OFFSIDER_RUN=off records nothing; OFFSIDER_RUN=<dir> records into <dir> whatever the session.
        """,
        subcommands: [RunStart.self, RunStop.self, RunStatus.self]
    )
}

/// The environment `main.swift` bound for this command; a run command without one cannot work.
@MainActor
private func runEnvironment() throws -> EvidenceRunEnvironment {
    guard let environment = EvidenceRecorder.current.environment else {
        throw RunRegistry.unavailable("Evidence runs are not available to this command.")
    }
    return environment
}

struct RunStart: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "start",
        abstract: "Start recording this session's screenshots and logs into a folder (a new one is created 0700)"
    )

    @Argument(help: ArgumentHelp("The run's folder; created when missing. A stopped run's folder continues its numbering.", valueName: "dir"))
    var dir: String

    @Option(help: ArgumentHelp("A name for the run, shown in the summary.", valueName: "text"))
    var label: String?

    @Flag(name: .customLong("mask-secure"), help: "Mask password fields in every capture of the run, on top of its own masks.")
    var maskSecure = false

    @Flag(name: .customLong("mask-emails"), help: "Mask email addresses in every capture of the run, on top of its own masks.")
    var maskEmails = false

    @Option(name: .customLong("mask-id"), parsing: .upToNextOption, help: ArgumentHelp("Mask elements with this id in every capture of the run, on top of its own masks. Repeatable.", valueName: "id"))
    var maskIDs: [String] = []

    @Flag(name: .customLong("json"), help: "Print one JSON object to stdout; human text goes to stderr.")
    var json = false

    @MainActor
    func run() async throws {
        let environment = try runEnvironment()
        let masks = RunMasks(secure: maskSecure, emails: maskEmails, ids: maskIDs)
        let started = try RunRegistry.start(dir, label: label, masks: masks, in: environment)
        let path = started.folder.path
        if started.writableByOthers {
            print("Warning: other users can write to \(path), so they could add or change files in the run.", to: &standardError)
        }
        if started.unchanged {
            print(Self.activeRunLine(path: path, masks: started.state.masks, added: started.addedMasks), to: &standardError)
        } else if started.continued {
            print("Continuing the run in \(path) from \(String(format: "%03d", started.state.next)).", to: &standardError)
        } else {
            print("Started a run in \(path); screenshots and logs from this session are numbered into it. Run `offsider run stop --summary` when done.", to: &standardError)
        }
        print(json ? started.state.startJSONLine(dir: path, continued: started.continued, timeZone: environment.timeZone) : path)
    }

    /// What `run start` says when this session's run already writes to the folder.
    static func activeRunLine(path: String, masks: RunMasks, added: Bool) -> String {
        let line = added
            ? "Added masks to the active run in \(path); masks now in force: \(masks.summary)."
            : "A run is already active in \(path) for this session; masks in force: \(masks.summary)."
        return masks.isEmpty ? line : line + " To remove one, run `offsider run stop`, then start the run again."
    }
}

struct RunStop: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "stop",
        abstract: "End this session's run; --summary prints its timeline"
    )

    @Flag(help: "Print the run's timeline: one line per capture, then counts of files, failures and unrecorded files.")
    var summary = false

    @Flag(name: .customLong("json"), help: "Print the timeline as one JSON object to stdout; human text goes to stderr.")
    var json = false

    @MainActor
    func run() async throws {
        let environment = try runEnvironment()
        guard let timeline = try RunRegistry.stop(in: environment) else {
            print(json ? RunState.noneJSONLine : "No run is active.")
            return
        }
        if json {
            print(timeline.jsonLine(timeZone: environment.timeZone))
        } else if summary {
            print(timeline.text(now: environment.now(), timeZone: environment.timeZone))
        } else {
            print("Stopped the run in \(timeline.dir): \(RunTimeline.count(timeline.files, "file")), \(RunTimeline.count(timeline.failures, "failure")).")
        }
    }
}

struct RunStatus: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Show this session's run, or with --all every live run of this user; runs whose session has exited are ended"
    )

    @Flag(help: "List every live run of this user, not only this session's.")
    var all = false

    @Flag(name: .customLong("json"), help: "Print one JSON object to stdout; human text goes to stderr.")
    var json = false

    @MainActor
    func run() async throws {
        let environment = try runEnvironment()
        let status = try RunRegistry.status(all: all, in: environment)
        if json {
            print(RunStatusEntry.jsonLine(runs: status.runs, ended: status.ended, timeZone: environment.timeZone))
            return
        }
        let lines = (status.ended + status.runs).map { $0.text(timeZone: environment.timeZone) }
        print(lines.isEmpty ? "No run is active." : lines.joined(separator: "\n"))
    }
}
