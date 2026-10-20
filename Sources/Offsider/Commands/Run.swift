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
        `run stop --summary` ends the run and prints its timeline. A run masks password fields and email addresses in \
        every capture unless started with --no-mask-secure or --no-mask-emails; its masks apply on top of the capture's own, \
        and a capture's --no-mask-secure never drops the run's. `run start` again on the active folder adds the masks its \
        flags name and never removes one. A folder `run start` creates gets a .gitignore of `*`. The one exception: `screenshot --mask-skip-beneath` leaves the run's email and id matches unpainted on a \
        screen beneath a page; password fields always stay masked. OFFSIDER_RUN=off records nothing; OFFSIDER_RUN=<dir> \
        records into <dir> whatever the session, with the default masks unless `run start` set others there.
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

    @Flag(name: .customLong("mask-secure"), inversion: .prefixedNo, help: "Mask password fields in every capture of the run, on top of its own masks (the default).")
    var maskSecure: Bool?

    @Flag(name: .customLong("mask-emails"), inversion: .prefixedNo, help: "Mask email addresses in every capture of the run, on top of its own masks (the default).")
    var maskEmails: Bool?

    @Option(name: .customLong("mask-id"), parsing: .upToNextOption, help: ArgumentHelp("Mask elements with this id in every capture of the run, on top of its own masks. Repeatable.", valueName: "id"))
    var maskIDs: [String] = []

    @Flag(name: .customLong("json"), help: "Print one JSON object to stdout; human text goes to stderr.")
    var json = false

    @MainActor
    func run() async throws {
        let environment = try runEnvironment()
        let masks = RunMasks(secure: maskSecure ?? true, emails: maskEmails ?? true, ids: maskIDs)
        let explicit = RunMasks(secure: maskSecure == true, emails: maskEmails == true, ids: maskIDs)
        let started = try RunRegistry.start(dir, label: label, masks: masks, explicit: explicit, in: environment)
        let path = started.folder.path
        let console = Console.current
        var lines = StartPersonView.Lines(console: console)
        if !started.state.masks.secure {
            lines.add(
                "Warning: this run does not mask password fields, so a capture with --no-mask-secure or OFFSIDER_MASK_SECURE=0 shows them.",
                person: .warning("This run does not mask password fields; a capture with --no-mask-secure shows them")
            )
        }
        if started.writableByOthers {
            lines.add("Warning: other users can write to \(path), so they could add or change files in the run.", person: .warning("Other users can write to this run's folder"))
        }
        let start: StartPersonView.RunStart
        if started.unchanged {
            start = .active(added: started.addedMasks)
            lines.add(Self.activeRunLine(path: path, masks: started.state.masks, added: started.addedMasks), person: nil)
        } else if started.continued {
            start = .continued(next: started.state.next)
            lines.add("Continuing the run in \(path) from \(String(format: "%03d", started.state.next)).", person: nil)
        } else {
            start = .started
            lines.add("Started a run in \(path); screenshots and logs from this session are numbered into it. Run `offsider run stop --summary` when done.", person: nil)
        }
        if json {
            lines.flush()
            return console.data(started.state.startJSONLine(dir: path, continued: started.continued, timeZone: environment.timeZone) + "\n")
        }
        var page = StartPersonView.runStarted(path: path, state: started.state, start: start)
        page.notices = lines.notices + page.notices
        console.show(page)
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
        let console = Console.current
        guard let timeline = try RunRegistry.stop(in: environment) else {
            return json ? console.data(RunState.noneJSONLine + "\n") : console.show(StartPersonView.noRun)
        }
        if json {
            console.data(timeline.jsonLine(timeZone: environment.timeZone) + "\n")
        } else {
            console.show(StartPersonView.runStopped(timeline, summary: summary, now: environment.now(), timeZone: environment.timeZone))
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
        let console = Console.current
        if json {
            return console.data(RunStatusEntry.jsonLine(runs: status.runs, ended: status.ended, timeZone: environment.timeZone) + "\n")
        }
        console.show(StartPersonView.runStatus(runs: status.runs, ended: status.ended, timeZone: environment.timeZone))
    }
}
