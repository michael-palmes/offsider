import Foundation

/// What a person sees from `boot`, `run`, `lease`, `guide` and the video commands: receipts, tables and a spinner over each
/// pause. An agent keeps every line these commands always printed, byte for byte.
public enum StartPersonView {
    // MARK: Stderr

    /// Stderr lines an agent reads as they happen; a person's notices wait for the page, after its body.
    public struct Lines {
        public let console: Console
        public private(set) var notices: [Notice] = []

        public init(console: Console = .current) {
            self.console = console
        }

        /// `line` as it always read for an agent; `person`, if any, joins a person's notices.
        public mutating func add(_ line: String, person: Notice?) {
            if console.err.profile == .agent {
                console.data(line + "\n", to: .err)
            } else if let person {
                notices.append(person)
            }
        }

        /// A notice an agent reads now, as `Warning:` or `Note:`, and a person after the page's body.
        public mutating func add(_ notice: Notice) {
            if console.err.profile == .agent {
                console.notice(notice)
            } else {
                notices.append(notice)
            }
        }

        /// Shows a person's waiting notices now, for a run that ends without a page.
        public mutating func flush() {
            notices.forEach(console.notice)
            notices = []
        }
    }

    /// One step of a pause: the spinner's label on a person's terminal, else `line` as it always read.
    public static func step(_ line: String, label: String, console: Console = .current) {
        let err = console.err
        if err.profile == .person, err.animates {
            console.relabel(label)
        } else {
            console.data(line + "\n", to: .err)
        }
    }

    /// A dim stderr line for a person; an agent gets `line` as it always read, or nothing when it is nil.
    public static func aside(_ line: String?, person: String?, console: Console = .current) {
        let err = console.err
        if err.profile == .agent {
            if let line { console.data(line + "\n", to: .err) }
        } else if let person {
            console.data(err.canvas.style.dim(TerminalText.line(person, cap: TerminalText.maxErrorCharacters, keepsTab: false)) + "\n", to: .err)
        }
    }

    /// Wipes the line a person's Ctrl+C echoed `^C` on, so what follows starts clean; nothing for an agent or a still terminal.
    public static func clearLine(console: Console = .current) {
        let err = console.err
        guard err.profile == .person, err.animates else { return }
        console.data("\r" + String(repeating: " ", count: err.canvas.usable) + "\r", to: .err)
    }

    // MARK: Boot

    /// What a booter's progress line is to a person: a spinner step, a note worth keeping, or nothing because the receipt says it.
    public enum BootLine: Equatable, Sendable {
        case step(String)
        case note(String)
        case running
    }

    public static func bootLine(_ line: String) -> BootLine {
        let text = line.hasSuffix("...") ? String(line.dropLast(3)) : line.hasSuffix(".") ? String(line.dropLast()) : line
        if line.hasSuffix("...") || line.hasPrefix("Booting ") || line.hasPrefix("Waiting for ") || line.contains(" is already starting") {
            return .step(text)
        }
        if line.contains(" is already running as "), !line.contains("without gRPC") { return .running }
        return .note(text)
    }

    /// A booter's line: a spinner step now, or a note for the page; an agent reads the line itself.
    public static func bootProgress(_ line: String, lines: inout Lines) {
        switch bootLine(line) {
        case .step(let label): step(line, label: label, console: lines.console)
        case .note(let text): lines.add(line, person: .note(text))
        case .running: lines.add(line, person: nil)
        }
    }

    /// `boot`'s end: a person's receipt and next step; an agent's serial or UDID alone, which scripts capture.
    public static func booted(name: String, id: String, alreadyRunning: Bool, notices: [Notice] = []) -> Page {
        let shown = TerminalText.field(name, profile: .person)
        return Page(
            [.person([.outcome(.done(alreadyRunning ? "\(shown) was already running" : "\(shown) is running", details: [id]))]), .agent(id + "\n")],
            notices: notices + [.next("offsider describe-ui --device \(id)")]
        )
    }

    // MARK: Run

    /// How `run start` found the folder.
    public enum RunStart: Equatable, Sendable {
        case started
        case continued(next: Int)
        /// This session's run already writes there; `added` when the flags added masks.
        case active(added: Bool)
    }

    /// `run start`'s end: a person's receipt; an agent's folder path alone.
    public static func runStarted(path: String, state: RunState, start: RunStart, home: String = NSHomeDirectory()) -> Page {
        var details = [TerminalText.homePath(path, home: home)]
        if let label = state.label { details.append(TerminalText.field(label, profile: .person)) }
        let headline: String
        var notices: [Notice] = [.next("offsider run stop --summary")]
        switch start {
        case .started:
            headline = "Run started"
        case .continued(let next):
            headline = "Run continued"
            details.append(unsafe String(format: "next file %03d", next))
        case .active(let added):
            headline = added ? "Masks added to the run" : "Run already active"
            details.append("masks " + state.masks.summary)
            notices = state.masks.isEmpty ? [] : [.note("To drop a mask, stop the run and start it again", see: "offsider run stop")]
        }
        return Page([.person([.outcome(.done(headline, details: details))]), .agent(path + "\n")], notices: notices)
    }

    /// `run stop`'s end: a person's receipt with counts, under the timeline with `--summary`; an agent's line or timeline as it was.
    public static func runStopped(_ timeline: RunTimeline, summary: Bool, now: Date, timeZone: TimeZone = .current, home: String = NSHomeDirectory()) -> Page {
        let agent = summary
            ? timeline.text(now: now, timeZone: timeZone) + "\n"
            : "Stopped the run in \(timeline.dir): \(RunTimeline.count(timeline.files, "file")), \(RunTimeline.count(timeline.failures, "failure")).\n"
        let counts = [RunTimeline.count(timeline.files, "file"), RunTimeline.count(timeline.failures, "failure"), "\(timeline.unrecorded.count) unrecorded"]
        var person: [Block] = []
        if summary {
            let end = timeline.state.stoppedAt ?? now
            let span = "\(RunClock.clock(timeline.state.startedAt, separator: ":", timeZone: timeZone)) to \(RunClock.clock(end, separator: ":", timeZone: timeZone))"
            let title = timeline.state.label.map { "Run \(TerminalText.field($0, profile: .person))" } ?? "Run"
            person.append(.header(Header(.run, title, [span, RunClock.duration(from: timeline.state.startedAt, to: end)])))
            if !timeline.entries.isEmpty || !timeline.unrecorded.isEmpty { person.append(.table(runTable(timeline, timeZone: timeZone))) }
        }
        person.append(.outcome(.done("Run stopped", details: [TerminalText.homePath(timeline.dir, home: home), counts.joined(separator: ", ")])))
        return Page([.person(person), .agent(agent)])
    }

    /// One row per capture, failures marked, then each file the manifest does not name.
    private static func runTable(_ timeline: RunTimeline, timeZone: TimeZone) -> Table {
        let columns = [
            Table.Column(agent: nil, person: 0, fit: .whole, tone: .dim),
            Table.Column(agent: nil, person: 1, fit: .optional(priority: 2), tone: .dim),
            Table.Column(agent: nil, person: 2, fit: .cut(min: 10)),
            Table.Column(agent: nil, person: 3, fit: .optional(priority: 1), tone: .dim),
            Table.Column(agent: nil, person: 4, fit: .cut(min: 12, at: .middle)),
        ]
        var rows = timeline.entries.map { entry -> Table.Row in
            let notes = timeline.notes(for: entry)
            let result = entry.exit == 0 ? (entry.file ?? "ok") : (["exit \(entry.exit)"] + [entry.reason, entry.file].compactMap { $0 }).joined(separator: " ")
            return Table.Row([
                Table.Cell(entry.n.map { unsafe String(format: "%03d", $0) } ?? "---"),
                Table.Cell(RunClock.clock(entry.time, separator: ":", timeZone: timeZone)),
                Table.Cell(entry.step.map { "\(entry.command) step \($0)" } ?? entry.command),
                entry.device.map { Table.Cell($0, untrusted: true) },
                Table.Cell(result, tag: notes.isEmpty ? nil : notes.joined(separator: ", ")),
            ], status: entry.exit == 0 ? .ok : .fail)
        }
        rows += timeline.unrecorded.map { file in
            Table.Row([Table.Cell(String(file.prefix(3))), nil, Table.Cell("unrecorded"), nil, Table.Cell(file, untrusted: true)], status: .warn)
        }
        return Table(columns: columns, rows: rows)
    }

    /// `run stop` with no run: the same words for both.
    public static let noRun = Page([.person([.prose("No run is active.")]), .agent("No run is active.\n")])

    /// `run status`: a person's table of runs; an agent's lines as they were.
    public static func runStatus(runs: [RunStatusEntry], ended: [RunStatusEntry], timeZone: TimeZone = .current, home: String = NSHomeDirectory()) -> Page {
        let lines = (ended + runs).map { $0.text(timeZone: timeZone) }
        let agent = (lines.isEmpty ? "No run is active." : lines.joined(separator: "\n")) + "\n"
        guard !lines.isEmpty else { return Page([.person([.prose("No run is active.")]), .agent(agent)]) }
        let columns = [
            Table.Column(agent: nil, person: 0, fit: .cut(min: 8), tone: .bold),
            Table.Column(agent: nil, person: 1, fit: .cut(min: 16, at: .middle)),
            Table.Column(agent: nil, person: 2, fit: .optional(priority: 2), tone: .dim),
            Table.Column(agent: nil, person: 3, fit: .optional(priority: 1), tone: .dim),
        ]
        let rows = ended.map { run in
            Table.Row([runName(run), Table.Cell(TerminalText.homePath(run.dir, home: home), untrusted: true), Table.Cell(run.endedBy == "owner-exited" ? "its session exited" : (run.endedBy ?? "ended")), nil], status: .off)
        } + runs.map { run in
            Table.Row([
                runName(run), Table.Cell(TerminalText.homePath(run.dir, home: home), untrusted: true),
                Table.Cell("since \(RunClock.clock(run.startedAt, separator: ":", timeZone: timeZone))"), Table.Cell(RunTimeline.count(run.files, "file")),
            ], status: .on)
        }
        let summary = [runs.isEmpty ? nil : "\(runs.count) active", ended.isEmpty ? nil : "\(ended.count) ended"].compactMap { $0 }
        return Page([.person([.header(Header(.run, runs.count + ended.count == 1 ? "Run" : "Runs", summary)), .table(Table(columns: columns, rows: rows))]), .agent(agent)])
    }

    private static func runName(_ run: RunStatusEntry) -> Table.Cell {
        Table.Cell(run.label ?? "Run", untrusted: run.label != nil)
    }

    // MARK: Lease

    /// `lease set`: a person's receipt; an agent's sentence as `perform` wrote it.
    public static func leased(_ key: String, lease: DeviceLease, renewed: Bool, agentText: String, clock: (Date) -> String = DeviceLeaseRules.clock) -> Page {
        let label = TerminalText.field(lease.label, profile: .person)
        var details = ["until \(clock(lease.expires))"]
        var notices: [Notice] = []
        if let owner = lease.owner {
            details.append("for this session (\(owner.name), pid \(owner.pid))")
        } else {
            notices.append(.next("export \(DeviceLeaseRules.sessionVariable)=\(DeviceLeaseRules.shellQuoted(lease.label))"))
        }
        let headline = renewed ? "Lease on \(key) renewed for \(label)" : "\(key) leased to \(label)"
        return Page([.person([.outcome(.done(headline, details: details))]), .agent(agentText + "\n")], notices: notices)
    }

    /// `lease release`: a receipt when a lease went, the same words as an agent's when there was none.
    public static func released(_ key: String, lease: DeviceLease?, agentText: String) -> Page {
        guard let lease else { return Page([.person([.prose(agentText)]), .agent(agentText + "\n")]) }
        return Page([.person([.outcome(.done("Released \(key)", details: ["was leased to \(TerminalText.field(lease.label, profile: .person))"]))]), .agent(agentText + "\n")])
    }

    /// `lease show`: a person's table; an agent's lines as `perform` wrote them.
    public static func leases(_ leases: [LeasedDevice], agentText: String, clock: (Date) -> String = DeviceLeaseRules.clock) -> Page {
        guard !leases.isEmpty else { return Page([.person([.prose(agentText)]), .agent(agentText + "\n")]) }
        let columns = [
            Table.Column(agent: nil, person: 0, fit: .whole, tone: .bold),
            Table.Column(agent: nil, person: 1, fit: .cut(min: 10)),
            Table.Column(agent: nil, person: 2, fit: .optional(priority: 2), tone: .dim),
            Table.Column(agent: nil, person: 3, fit: .optional(priority: 1), tone: .dim),
        ]
        let rows = leases.map { leased in
            Table.Row([
                Table.Cell(leased.key), Table.Cell(leased.lease.label, untrusted: true),
                Table.Cell("\(clock(leased.lease.created)) to \(clock(leased.lease.expires))"), Table.Cell(leased.platform.rawValue),
            ], status: .on)
        }
        let header = Header(.keep, leases.count == 1 ? "Lease" : "Leases", ["\(leases.count) leased"])
        return Page([.person([.header(header), .table(Table(columns: columns, rows: rows))]), .agent(agentText + "\n")])
    }

    // MARK: Guide

    /// `guide` with no topic: a person's two columns, the topic cyan and when to read it dim; an agent's list as it was.
    public static func guideTopics(_ topics: [(name: String, about: String)], agentText: String, projectGuide: Bool) -> Page {
        let table = Table(columns: [
            Table.Column(agent: nil, person: 0, fit: .whole, tone: .command),
            Table.Column(agent: nil, person: 1, fit: .cut(min: 20), tone: .dim),
        ], rows: topics.map { Table.Row([Table.Cell($0.name), Table.Cell($0.about.replacingOccurrences(of: "`", with: ""))]) })
        let closing = projectGuide
            ? "Run `offsider guide <topic>` to print one, or `offsider guide --project .` for this project's own guide."
            : "Run `offsider guide <topic>` to print one."
        return Page([.person([.header(Header(.guide, "Guide", ["\(topics.count) topics"])), .table(table), .prose(closing)]), .agent(agentText)])
    }

    // MARK: Video

    /// The live line over a recording: `Recording emulator-5554  00:12  (Ctrl+C to stop)`.
    public static func recordingLabel(device: String, elapsed: TimeInterval) -> String {
        let seconds = max(0, Int(elapsed))
        let clock = unsafe String(format: "%02d:%02d", seconds / 60, seconds % 60)
        return "Recording \(device)  \(clock)  (Ctrl+C to stop)"
    }

    /// `record-video`'s end: a person's receipt; an agent's path alone.
    public static func videoSaved(path: String, seconds: TimeInterval, frames: Int, held: Int, home: String = NSHomeDirectory()) -> Page {
        let length = RunClock.duration(from: Date(timeIntervalSinceReferenceDate: 0), to: Date(timeIntervalSinceReferenceDate: seconds))
        let stats = [length, RunTimeline.count(frames, "frame")] + (held > 0 ? ["\(held) held"] : [])
        return Page([.person([.outcome(.done("Video saved", details: [TerminalText.homePath(path, home: home), stats.joined(separator: ", ")]))]), .agent(path + "\n")])
    }

    /// `stream-video`'s one dim line for a person: what streams, how, and how to stop it.
    public static func streamHeader(device: String, format: String, fps: Int?) -> String {
        "Streaming \(device) as \(format)" + (fps.map { " at \($0) fps" } ?? "") + "  (Ctrl+C to stop)"
    }
}
