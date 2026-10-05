import Foundation

/// What `run stop --summary` prints: one line per manifest entry between a header and the counts.
public struct RunTimeline: Equatable, Sendable {
    public let dir: String
    public let state: RunState
    public let entries: [RunManifestLine]
    public let unrecorded: [String]

    public init(dir: String, state: RunState, entries: [RunManifestLine], unrecorded: [String]) {
        self.dir = dir
        self.state = state
        self.entries = entries
        self.unrecorded = unrecorded
    }

    public var files: Int { entries.filter { $0.file != nil }.count }
    public var failures: Int { entries.filter { $0.exit != 0 }.count }

    /// `Run "PR 123" in /tmp/run, 14:01:07 to 14:32:50 (31 min 43 s)`, the entries, then `3 files, 1 failure, 0 unrecorded`.
    public func text(now: Date, timeZone: TimeZone = .current) -> String {
        let end = state.stoppedAt ?? now
        let name = state.label.map { "Run \"\($0)\"" } ?? "Run"
        var lines = ["\(name) in \(dir), \(RunClock.clock(state.startedAt, separator: ":", timeZone: timeZone)) to \(RunClock.clock(end, separator: ":", timeZone: timeZone)) (\(RunClock.duration(from: state.startedAt, to: end)))"]
        lines += entries.map { line(for: $0, timeZone: timeZone) }
        lines += unrecorded.map { "\($0.prefix(3)) unrecorded \($0)" }
        lines.append("\(Self.count(files, "file")), \(Self.count(failures, "failure")), \(unrecorded.count) unrecorded")
        return lines.joined(separator: "\n")
    }

    /// `001 14:03:22 screenshot emulator-5554 ok 001-screenshot-14.03.22.png (masked 2)`, or `--- … exit 1 mask_unproven` for a failure without a file.
    func line(for entry: RunManifestLine, timeZone: TimeZone) -> String {
        var parts = [entry.n.map { String(format: "%03d", $0) } ?? "---", RunClock.clock(entry.time, separator: ":", timeZone: timeZone)]
        parts.append(entry.step.map { "\(entry.command) step \($0)" } ?? entry.command)
        if let device = entry.device { parts.append(device) }
        if entry.exit == 0 {
            parts.append("ok")
        } else {
            parts.append("exit \(entry.exit)")
            if let reason = entry.reason { parts.append(reason) }
        }
        if let file = entry.file { parts.append(file) }
        var notes: [String] = []
        if let masked = entry.masked, masked > 0 { notes.append("masked \(masked)") }
        if let changed = entry.changed { notes.append(changed ? "changed" : "unchanged") }
        if let entries = entry.entries { notes.append(Self.count(entries, "entry", plural: "entries")) }
        if let redacted = entry.redacted, redacted > 0 { notes.append("redacted \(redacted)") }
        if let diff = entry.diff { notes.append("diff \(diff)") }
        if !notes.isEmpty { parts.append("(\(notes.joined(separator: ", ")))") }
        return parts.joined(separator: " ")
    }

    /// `{"version":1,"dir","label","startedAt","stoppedAt","entries":[…],"files","failures","unrecorded":[…]}`.
    public func jsonLine(timeZone: TimeZone = .current) -> String {
        OrderedJSON.object([
            ("version", .integer(1)),
            ("dir", .string(dir)),
            ("label", .optional(state.label, OrderedJSON.string)),
            ("startedAt", .string(RunClock.iso(state.startedAt, timeZone: timeZone))),
            ("stoppedAt", .optional(state.stoppedAt) { .string(RunClock.iso($0, timeZone: timeZone)) }),
            ("entries", .array(entries.map { $0.json(timeZone: timeZone) })),
            ("files", .integer(files)),
            ("failures", .integer(failures)),
            ("unrecorded", .array(unrecorded.map(OrderedJSON.string))),
        ]).rendered(compact: true)
    }

    public static func count(_ value: Int, _ singular: String, plural: String? = nil) -> String {
        "\(value) \(value == 1 ? singular : plural ?? singular + "s")"
    }
}

/// What `run status --json` prints for one run.
public struct RunStatusEntry: Equatable, Sendable {
    public let dir: String
    public let label: String?
    public let startedAt: Date
    public let owner: ProcessIdentity?
    public let files: Int
    /// `owner-exited` for a run ended because its session went away.
    public let endedBy: String?

    public init(dir: String, label: String?, startedAt: Date, owner: ProcessIdentity?, files: Int, endedBy: String? = nil) {
        self.dir = dir
        self.label = label
        self.startedAt = startedAt
        self.owner = owner
        self.files = files
        self.endedBy = endedBy
    }

    func json(timeZone: TimeZone) -> OrderedJSON {
        .object([
            ("dir", .string(dir)),
            ("label", .optional(label, OrderedJSON.string)),
            ("startedAt", .string(RunClock.iso(startedAt, timeZone: timeZone))),
            ("owner", .optional(owner) { .object([("pid", .integer(Int($0.pid))), ("name", .string($0.name))]) }),
            ("files", .integer(files)),
            ("endedBy", .optional(endedBy, OrderedJSON.string)),
        ])
    }

    /// `{"version":1,"runs":[…],"ended":[…]}`: live runs, then runs just ended because their session had gone.
    public static func jsonLine(runs: [RunStatusEntry], ended: [RunStatusEntry], timeZone: TimeZone = .current) -> String {
        OrderedJSON.object([
            ("version", .integer(1)),
            ("runs", .array(runs.map { $0.json(timeZone: timeZone) })),
            ("ended", .array(ended.map { $0.json(timeZone: timeZone) })),
        ]).rendered(compact: true)
    }

    /// `Run "PR 123" in /tmp/run since 14:01:07: 4 files (node 812)`.
    public func text(timeZone: TimeZone = .current) -> String {
        let name = label.map { "Run \"\($0)\"" } ?? "Run"
        if let endedBy {
            return "\(name) in \(dir) ended: \(endedBy == "owner-exited" ? "the session that started it has exited" : endedBy)."
        }
        let owner = self.owner.map { " (\($0.name) \($0.pid))" } ?? ""
        return "\(name) in \(dir) since \(RunClock.clock(startedAt, separator: ":", timeZone: timeZone)): \(RunTimeline.count(files, "file"))\(owner)"
    }
}

extension RunState {
    /// What `run start --json` prints: `{"version":1,"dir","label","startedAt","next","continued","masks":{…}}`.
    public func startJSONLine(dir: String, continued: Bool, timeZone: TimeZone = .current) -> String {
        OrderedJSON.object([
            ("version", .integer(1)),
            ("dir", .string(dir)),
            ("label", .optional(label, OrderedJSON.string)),
            ("startedAt", .string(RunClock.iso(startedAt, timeZone: timeZone))),
            ("next", .integer(next)),
            ("continued", .bool(continued)),
            ("masks", .object([
                ("secure", .bool(masks.secure)),
                ("emails", .bool(masks.emails)),
                ("ids", .array(masks.ids.map(OrderedJSON.string))),
            ])),
        ]).rendered(compact: true)
    }

    /// `{"version":1,"active":false}`, for `run stop --json` when no run is active.
    public static let noneJSONLine = #"{"version":1,"active":false}"#
}
