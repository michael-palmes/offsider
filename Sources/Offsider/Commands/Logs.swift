import ArgumentParser
import Foundation
import OffsiderCore

/// The zone text output gives its times in; JSON is always UTC.
enum LogZoneChoice: String, CaseIterable, ExpressibleByArgument {
    case local
    case utc

    var timeZone: TimeZone {
        self == .utc ? TimeZone(identifier: "UTC") ?? .gmt : .current
    }
}

struct Logs: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "logs",
        abstract: "Print the device's recent log entries, or collect live ones for a while",
        discussion: """
        Reads the last 30 seconds by default. Choose a source (--rn, --app, both, or --process) and one window \
        (--last, --since, --duration or --follow). ANSI escape sequences, including escaped colour codes such as \\u001b[32m, \
        are removed; --raw keeps colour codes only. Text output keeps each entry on one line, a newline showing as \\n. \
        Passwords, tokens, keys, cookies, JWTs, email addresses, wallet addresses, card numbers, recovery phrases and one-time \
        codes are replaced with markers such as [redacted]; --grep and --exclude match the text after redaction. Without \
        --rn, --app or --process, offsider.login.json's app is read when it names one, else the whole device's log, and stderr says which; \
        --all reads the whole device. On a physical phone the log is read one allowed app at a time (the only pinned app by default); \
        its whole log needs a person to choose "Any app and all logs" in `offsider device-access allow`. Exits 0 even when nothing matches. On iOS this reads the simulator's unified log, which keeps about 1 KB of a message \
        and ends a longer one <…> (marked [truncated], or "truncated": true in JSON); on Android, logcat.

        --rn reads React Native's own log (the com.facebook.react.log subsystem on iOS, the ReactNativeJS and \
        ReactNative tags on Android). An app's console output can also log outside it, so --rn --app reads both: \
        React Native's log and everything the app's process logs (on Android, every process of the app's user ID, \
        so lines from before a restart are kept and the app need not be running).
        """
    )

    @Flag(name: .customLong("rn"), help: "React Native JavaScript and native logs; with --app, also everything that app logs.")
    var reactNative = false

    @Option(help: ArgumentHelp("Only this app's process: a bundle ID on iOS (it must be installed), a package on Android (it must be running).", valueName: "bundle-id|package"))
    var app: String?

    @Option(help: ArgumentHelp("Only processes with this name, such as SpringBoard.", valueName: "name"))
    var process: String?

    @Option(help: ArgumentHelp("iOS only: an NSPredicate for `log`, combined with the source by AND, such as 'messageType == error'.", valueName: "predicate"))
    var predicate: String?

    @Option(help: ArgumentHelp("Entries from this long ago until now: 500ms, 30s, 2m, 1h, or bare seconds, up to 8760h (default 30s).", valueName: "duration"))
    var last: String?

    @Option(help: ArgumentHelp("Entries from this time until now: ISO 8601 (the Mac's zone unless given) or seconds since 1970.", valueName: "time"))
    var since: String?

    @Option(help: ArgumentHelp("Collect live entries for this many seconds, from 1 to 300, then print them and exit.", valueName: "seconds"))
    var duration: Double?

    @Flag(help: "Print live entries as they arrive until interrupted (Ctrl+C). With --json, one compact entry object per line.")
    var follow = false

    @Flag(name: .customLong("all"), help: "Read the whole device's log, every app's included, even when offsider.login.json names an app.")
    var all = false

    @Option(help: ArgumentHelp("Only entries whose message matches this case-insensitive regular expression, after ANSI codes are removed and values redacted.", valueName: "regex"))
    var grep: String?

    @Option(name: .customLong("exclude"), help: ArgumentHelp("Drop entries whose message matches this case-insensitive regular expression, as --grep matches; repeat for more. Dropped entries reach neither stdout nor an evidence run.", valueName: "regex"))
    var exclude: [String] = []

    @Option(name: .customLong("max-lines"), help: ArgumentHelp("Keep the newest this many matching entries; older ones are dropped and stderr says how many. 0 keeps all. Ignored with --follow.", valueName: "n"))
    var maxLines: Int = 500

    @Option(name: .customLong("tz"), help: ArgumentHelp("Text output times in this Mac's zone (local, the default) or UTC; each ends with its offset, such as +10:30 or Z. JSON is always UTC.", valueName: "local|utc"))
    var tz: LogZoneChoice = .local

    @Flag(help: "Keep ANSI colour codes in messages; other escape sequences are still removed, and redaction stays on.")
    var raw = false

    @Flag(inversion: .prefixedNo, help: "Replace passwords, tokens, keys, cookies, JWTs, emails, wallet addresses, card numbers, recovery phrases and one-time codes with markers (the default).")
    var redact: Bool?

    @Flag(name: .customLong("json"), help: "Print one JSON object to stdout; human text goes to stderr.")
    var json = false

    @OptionGroup
    var deviceOption: ReadDeviceOption

    static let defaultLast = "30s"

    func validate() throws {
        try Self.check { _ = try query() }
        try Self.check { _ = try collector() }
    }

    /// The source and window the flags ask for; throws a `LogOptionError` for conflicts and bad values.
    func query() throws -> LogQuery {
        let sources = [(reactNative, "--rn"), (app != nil, "--app"), (process != nil, "--process")].filter(\.0).map(\.1)
        if all, !sources.isEmpty {
            throw LogOptionError("--all reads the whole device's log: drop \(Self.list(sources)), or drop --all.")
        }
        if process != nil, sources.count > 1 {
            throw LogOptionError("--process reads one process alone: drop \(Self.list(sources.filter { $0 != "--process" })), or drop --process. --rn and --app combine.")
        }
        let windows = [(last != nil, "--last"), (since != nil, "--since"), (duration != nil, "--duration"), (follow, "--follow")].filter(\.0).map(\.1)
        if windows.count > 1 {
            throw LogOptionError("Use only one of --last, --since, --duration or --follow; got \(Self.list(windows)).")
        }
        if let app, app.trimmingCharacters(in: .whitespaces).isEmpty {
            throw LogOptionError("--app needs a bundle ID or package.")
        }
        if let process, process.trimmingCharacters(in: .whitespaces).isEmpty {
            throw LogOptionError("--process needs a process name.")
        }
        if let predicate, predicate.trimmingCharacters(in: .whitespaces).isEmpty {
            throw LogOptionError("--predicate needs an NSPredicate, such as 'messageType == error'.")
        }

        let source: LogSource
        if reactNative {
            source = .reactNative(app: app)
        } else if let app {
            source = .app(app)
        } else if let process {
            source = .process(process)
        } else {
            source = .all
        }

        let window: LogWindow
        if let since {
            window = .since(try LogWindow.parseTime(since))
        } else if let duration {
            guard (1...300).contains(duration) else {
                throw LogOptionError("--duration must be from 1 to 300 seconds; use --follow to stream until interrupted.")
            }
            window = .live(.milliseconds(Int64((duration * 1000).rounded())))
        } else if follow {
            window = .live(nil)
        } else {
            window = .last(try LogWindow.parseDuration(last ?? Self.defaultLast))
        }
        return LogQuery(source: source, window: window, predicate: predicate)
    }

    func collector() throws -> LogCollector {
        try LogCollector(maxLines: follow ? 0 : maxLines, grep: grep, exclude: exclude, keepsANSI: raw, redacts: redacts, retainsEntries: !follow)
    }

    /// `--redact` or `--no-redact` when given, else on; `--raw` never turns it off.
    var redacts: Bool {
        redact ?? true
    }

    func run() async throws {
        let logger = OffsiderLogger()
        try await read(from: try await DeviceRouter.route(deviceOption.id, logger: logger))
    }

    /// Writes one line of stdout at once, so a reader of `--follow` sees each entry as it arrives.
    @MainActor
    static func printLine(_ line: String) {
        Console.current.data(line + "\n")
    }

    /// A stderr line as it is for an agent; a warning or a note for a person.
    static func printNote(_ line: String) {
        Console.current.line(line, person: personNotice(line))
    }

    /// A person's few words for the notes most reads print; the rest read as they are.
    static func personNotice(_ line: String) -> Notice {
        if line == wholeLogNote { return .note("Reading every app's log; --app, --rn or --process reads one", mark: .logs) }
        let following = "Following logs on "
        let stop = "; press Ctrl+C to stop."
        if line.hasPrefix(following), line.hasSuffix(stop) {
            return .note("Following logs on \(line.dropFirst(following.count).dropLast(stop.count)) · Ctrl+C stops", mark: .logs)
        }
        return ReadPersonView.logNotice(line)
    }

    /// `write` receives each line meant for stdout, and `note` each one meant for stderr, without its newline.
    @MainActor
    func read(from route: DeviceRouter.Route, note: @escaping @MainActor (String) -> Void = Logs.printNote, write: @escaping @MainActor (String) -> Void = Logs.printLine) async throws {
        let backend = route.backend
        try await backend.prepare()
        let booted = try await backend.requireBootedDevice(route.device)
        guard let reader = backend as? any LogReading else {
            throw CLIError(errorDescription: "logs is not available for \(booted.id.platform.rawValue) devices in this build.", reason: .notSupported)
        }
        let asked = try Self.options { try self.query() }
        let (query, scopeNote) = try Self.scoped(
            asked, all: all, platform: booted.id.platform, allowance: route.allowance,
            policy: route.allowance.map { _ in DevicePolicyGate.current.policy() }, profile: Self.profile
        )
        if let scopeNote {
            note(scopeNote)
        } else if query.source == .all {
            note(Self.wholeLogNote)
        }
        let sink = LogSink(try Self.options { try self.collector() })
        let recorder = EvidenceRecorder.current
        let token = try recorder.begin(device: booted.id, kind: "logs")
        let runFile = token.flatMap { Self.openRunFile($0, recorder: recorder, extension: json ? (follow ? "ndjson" : "json") : "log") }
        let teeing = RunLogTee(stdout: write, runFile: runFile) { error in
            recorder.update(token) { $0.file = nil }
            Self.warnRunWriteFailed(error)
        }
        defer { teeing.close() }
        let tee: @MainActor (String) -> Void = { teeing.write($0) }

        let follow = self.follow
        let json = self.json
        let raw = self.raw
        let zone = tz.timeZone
        let device = booted.id.rawValue
        let reading = Task { @MainActor in
            try await reader.readLogs(query, on: booted.id, onEntry: { entry in
                sink.retention.add(entry)
                guard let shown = sink.collector.add(entry), follow else { return }
                tee(json ? LogReport.jsonLine(shown) : LogText.format(shown, timeZone: zone, keepsColour: raw))
            }, onNote: { logNote in
                switch logNote {
                case .clockSkew(let seconds): note(LogClock.note(seconds, device: device))
                }
            })
        }
        let signalObserver = SignalObserver(signals: [SIGINT, SIGTERM]) {
            reading.cancel()
        }
        defer { signalObserver.invalidate() }
        if follow {
            note("Following logs on \(booted.id.rawValue); press Ctrl+C to stop.")
        }
        let started = Date()
        if follow {
            try await reading.value
        } else {
            try await Console.current.progress(duration.map { "Collecting logs for \(WaitLoop.seconds($0))" } ?? "Reading logs") { try await reading.value }
        }
        if !follow {
            Self.emit(sink.collector, platform: booted.id.platform, device: booted.id.rawValue, json: json, timeZone: zone, keepsColour: raw, write: tee, note: note)
        }
        if booted.id.platform == .ios, let cutoff = query.window.cutoff(now: started), let warning = sink.retention.warning(cutoff: cutoff, timeZone: zone) {
            note(warning)
        }
        for footer in [Self.redactionFooter(sink.collector.redacted), Self.cutFooter(sink.collector.cut), Self.excludedFooter(sink.collector.excluded)] {
            if let footer { note(footer) }
        }
        if !follow, let hint = Self.appHint(for: query.source, matched: sink.collector.matched, grepping: grep != nil, platform: booted.id.platform) {
            note(hint)
        }
        let collector = sink.collector
        recorder.update(token) { entry in
            entry.entries = follow ? collector.matched : collector.entries.count
            entry.redacted = collector.redacted
        }
    }

    /// The run's copy of stdout; stdout is always the other copy, so a file that cannot be made is a warning.
    @MainActor
    private static func openRunFile(_ token: EvidenceRecorder.Token, recorder: EvidenceRecorder, extension pathExtension: String) -> FileHandle? {
        do {
            let path = try recorder.reserveFile(token, extension: pathExtension)
            return FileHandle(fileDescriptor: try RunFolder.createNew(path), closeOnDealloc: true)
        } catch {
            recorder.update(token) { $0.file = nil }
            warnRunWriteFailed(error)
            return nil
        }
    }

    static func warnRunWriteFailed(_ error: any Error) {
        printNote("Warning: could not write the logs into the run: \(TerminalText.line(OffsiderCommand.message(for: error), cap: TerminalText.maxErrorCharacters)).")
    }

    /// The stderr line after a read that redacted something; nil when nothing was.
    static func redactionFooter(_ count: Int) -> String? {
        guard count > 0 else { return nil }
        return "Redacted \(count) \(count == 1 ? "value" : "values") (passwords, tokens, emails, addresses, cards, phrases, codes)."
    }

    /// The stderr line before a read of the whole device's log.
    static let wholeLogNote = "Reading the whole device's log, every app's included; pass --app, --rn or --process to read only the app under test."

    /// offsider.login.json in this folder or above; tests bind their own.
    @TaskLocal static var profile: @Sendable () -> LoginProfile? = { (try? LoginProfiles.load(project: nil, warn: { _ in })) ?? nil }

    /// The app offsider.login.json names for this platform.
    static func profileApp(_ profile: LoginProfile?, platform: DevicePlatform) -> String? {
        (platform == .ios ? profile?.bundleID : profile?.package).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// The source a read may use, and the stderr line that says what changed. On a physical phone every app must be within the allowance,
    /// and the whole log needs its `*` pin; elsewhere offsider.login.json's app replaces the whole log unless `--all` asks for it.
    static func scoped(
        _ query: LogQuery, all: Bool, platform: DevicePlatform, allowance: DeviceAllowance?, policy: PhysicalDevicePolicy?, profile: () -> LoginProfile?
    ) throws -> (LogQuery, note: String?) {
        guard let allowance, let policy else {
            guard !all, query.source == .all, let profileApp = profileApp(profile(), platform: platform) else { return (query, nil) }
            var scoped = query
            scoped.source = .app(profileApp)
            return (scoped, "Reading only \(profileApp)'s log, which offsider.login.json names; pass --all for the whole device's.")
        }
        let gate = DevicePolicyGate.fixed(policy)
        let whole = allowance.allowsWholeDevice
        let pins = allowance.pinnedApps.filter { policy.permits(app: $0, on: allowance) }
        let fallback = pins.count == 1 ? pins[0] : profileApp(profile(), platform: platform).flatMap { policy.permits(app: $0, on: allowance) ? $0 : nil }
        var scoped = query
        switch query.source {
        case .app(let app), .reactNative(app: let app?):
            try gate.requireApp(app, on: allowance)
            return (query, nil)
        case .all where whole && (all || fallback == nil):
            return (query, nil)
        case .reactNative(nil) where whole:
            return (query, nil)
        case .process where whole:
            return (query, nil)
        case .all where !all, .reactNative(nil):
            guard let fallback else { throw phoneAppRequired(allowance) }
            scoped.source = query.source == .all ? .app(fallback) : .reactNative(app: fallback)
            let tail = whole ? "pass --all for the whole log" : "a phone's log is read one allowed app at a time"
            return (scoped, "Reading only \(fallback)'s log on \(allowance.name); \(tail).")
        case .all, .process:
            throw phoneWholeLogRefused(allowance)
        }
    }

    static func phoneAppRequired(_ allowance: DeviceAllowance) -> CLIError {
        CLIError(
            errorDescription: "A phone's log is read one allowed app at a time, and none is named for \(allowance.name) (\(allowance.key)). Nothing was read. Pass --app <package>.",
            reason: .appNotAllowed, hint: "offsider device-access allow"
        )
    }

    static func phoneWholeLogRefused(_ allowance: DeviceAllowance, audience: ErrorAudience = .current) -> CLIError {
        CLIError(
            errorDescription: "Reading the whole log of \(allowance.name) (\(allowance.key)) needs a person to choose \"Any app and all logs\" for it, so nothing was read. Pass --app <package> to read one allowed app."
                + audience.personStep("offsider device-access allow", agentTail: ", choose \(allowance.name) and \"Any app and all logs\""),
            reason: .appNotAllowed, hint: "offsider device-access allow"
        )
    }

    /// The stderr line after a read whose entries the device's log cut short; nil when none were.
    static func cutFooter(_ count: Int) -> String? {
        guard count > 0 else { return nil }
        let entries = count == 1 ? "1 entry was" : "\(count) entries were"
        let ending = count == 1 ? "it ends" : "they end"
        return "\(entries) cut by iOS's log, which keeps about 1 KB of a message (\(ending) \(LogText.iosTruncationMarker)); the rest was never stored. In a debug build, rn logbox open shows the whole error."
    }

    /// The stderr line after a read that `--exclude` dropped entries from; nil when it dropped none.
    static func excludedFooter(_ count: Int) -> String? {
        guard count > 0 else { return nil }
        return "Excluded \(count) \(count == 1 ? "entry" : "entries") (--exclude)."
    }

    @MainActor
    static func emit(
        _ collector: LogCollector, platform: DevicePlatform, device: String, json: Bool, timeZone: TimeZone = .current, keepsColour: Bool = false,
        write: (String) -> Void, note: (String) -> Void = Logs.printNote
    ) {
        let entries = collector.entries
        if json {
            write(LogReport(platform: platform, device: device, entries: entries, truncated: collector.truncated, redacted: collector.redacted, excluded: collector.excluded).jsonLine())
        } else if !entries.isEmpty {
            write(entries.map { LogText.format($0, timeZone: timeZone, keepsColour: keepsColour) }.joined(separator: "\n"))
        }
        if collector.truncated > 0 {
            note("Showing the newest \(entries.count) of \(entries.count + collector.truncated) entries; raise --max-lines or narrow with --grep.")
        }
    }

    /// Fewer `--rn` entries than this suggest the app's own console output is logging elsewhere.
    static let fewReactNativeEntries = 5

    /// The stderr hint after a `--rn` read without `--app` that found few entries (none, with `--grep`); nil otherwise.
    static func appHint(for source: LogSource, matched: Int, grepping: Bool = false, platform: DevicePlatform) -> String? {
        guard source == .reactNative(app: nil), matched < (grepping ? 1 : fewReactNativeEntries) else { return nil }
        let place = platform == .ios ? "its own process" : "its own tags"
        let id = platform == .ios ? "bundle-id" : "package"
        return "Only \(matched) React Native \(matched == 1 ? "entry" : "entries"). An app's console output can log under \(place) instead; add --app <\(id)> to read both."
    }

    private static func list(_ flags: [String]) -> String {
        if flags.count == 1 { return flags[0] }
        return flags.count == 2 ? "\(flags[0]) and \(flags[1])" : flags.dropLast().joined(separator: ", ") + " and " + flags[flags.count - 1]
    }

    private static func check(_ body: () throws -> Void) throws {
        do {
            try body()
        } catch let error as LogOptionError {
            throw ValidationError(error.message)
        }
    }

    private static func options<T>(_ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch let error as LogOptionError {
            throw CLIError(errorDescription: error.message, reason: .logStreamFailed)
        }
    }
}

@MainActor
private final class LogSink {
    var collector: LogCollector
    var retention = LogRetention()

    init(_ collector: LogCollector) {
        self.collector = collector
    }
}

/// Every line to stdout and to the run's copy; the first failed run write closes the copy and reports once, and stdout carries on.
@MainActor
final class RunLogTee {
    private let stdout: @MainActor (String) -> Void
    private var runFile: FileHandle?
    private let failed: @MainActor (any Error) -> Void

    init(stdout: @escaping @MainActor (String) -> Void, runFile: FileHandle?, failed: @escaping @MainActor (any Error) -> Void) {
        self.stdout = stdout
        self.runFile = runFile
        self.failed = failed
    }

    func write(_ line: String) {
        stdout(line)
        guard let handle = runFile else { return }
        do {
            try handle.write(contentsOf: Data((line + "\n").utf8))
        } catch {
            runFile = nil
            try? handle.close()
            failed(error)
        }
    }

    func close() {
        try? runFile?.close()
        runFile = nil
    }
}
