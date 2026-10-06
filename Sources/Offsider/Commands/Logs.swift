import ArgumentParser
import Foundation
import OffsiderCore

struct Logs: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "logs",
        abstract: "Print the device's recent log entries, or collect live ones for a while",
        discussion: """
        Reads the last 30 seconds by default. Choose one source (--rn, --app or --process) and one window \
        (--last, --since, --duration or --follow). ANSI colour codes, including escaped forms such as \\u001b[32m, \
        are removed unless --raw. Passwords, tokens, keys, cookies, JWTs and email addresses are replaced with \
        [redacted] unless --no-redact (or --raw alone); --grep matches the text before redaction. Exits 0 even when \
        nothing matches. On iOS this reads the simulator's unified log; on Android, logcat.
        """
    )

    @Flag(name: .customLong("rn"), help: "React Native JavaScript and native logs.")
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

    @Option(help: ArgumentHelp("Only entries whose message matches this case-insensitive regular expression, after ANSI codes are removed.", valueName: "regex"))
    var grep: String?

    @Option(name: .customLong("max-lines"), help: ArgumentHelp("Keep the newest this many entries; 0 keeps all. Ignored with --follow.", valueName: "n"))
    var maxLines: Int = 500

    @Flag(help: "Keep ANSI colour codes in messages; also turns redaction off unless --redact is given.")
    var raw = false

    @Flag(inversion: .prefixedNo, help: "Replace passwords, tokens, keys, cookies, JWTs and email addresses with [redacted] (default on, off with --raw).")
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
        if sources.count > 1 {
            throw LogOptionError("Use only one of --rn, --app or --process; got \(Self.list(sources)).")
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
            source = .reactNative
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
        try LogCollector(maxLines: follow ? 0 : maxLines, grep: grep, keepsANSI: raw, redacts: redacts, retainsEntries: !follow)
    }

    /// `--redact` or `--no-redact` when given, else on unless `--raw`.
    var redacts: Bool {
        redact ?? !raw
    }

    func run() async throws {
        let logger = OffsiderLogger()
        try await read(from: try await DeviceRouter.route(deviceOption.id, logger: logger))
    }

    /// Prints one line of stdout at once, so a reader of `--follow` sees each entry as it arrives.
    @MainActor
    static func printLine(_ line: String) {
        print(line)
        fflush(stdout)
    }

    /// `write` receives each line meant for stdout, without its newline.
    @MainActor
    func read(from route: DeviceRouter.Route, write: @escaping @MainActor (String) -> Void = Logs.printLine) async throws {
        let backend = route.backend
        try await backend.prepare()
        let booted = try await backend.requireBootedDevice(route.device)
        guard let reader = backend as? any LogReading else {
            throw CLIError(errorDescription: "logs is not available for \(booted.id.platform.rawValue) devices in this build.", reason: .notSupported)
        }
        let query = try Self.options { try self.query() }
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
        let reading = Task { @MainActor in
            try await reader.readLogs(query, on: booted.id) { entry in
                guard let shown = sink.collector.add(entry), follow else { return }
                tee(json ? LogReport.jsonLine(shown) : LogText.format(shown))
            }
        }
        let signalObserver = SignalObserver(signals: [SIGINT, SIGTERM]) {
            reading.cancel()
        }
        defer { signalObserver.invalidate() }
        if follow {
            print("Following logs on \(booted.id.rawValue); press Ctrl+C to stop.", to: &standardError)
        }
        try await reading.value
        if !follow {
            Self.emit(sink.collector, platform: booted.id.platform, device: booted.id.rawValue, json: json, write: tee)
        }
        if let footer = Self.redactionFooter(sink.collector.redacted) {
            print(footer, to: &standardError)
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
            guard FileManager.default.createFile(atPath: path, contents: nil, attributes: [.posixPermissions: 0o600]),
                  let handle = FileHandle(forWritingAtPath: path) else {
                throw CLIError(errorDescription: "could not create \(path)")
            }
            return handle
        } catch {
            recorder.update(token) { $0.file = nil }
            warnRunWriteFailed(error)
            return nil
        }
    }

    static func warnRunWriteFailed(_ error: any Error) {
        print("Warning: could not write the logs into the run: \(OffsiderCommand.message(for: error)).", to: &standardError)
    }

    /// The stderr line after a read that redacted something; nil when nothing was.
    static func redactionFooter(_ count: Int) -> String? {
        guard count > 0 else { return nil }
        return "Redacted \(count) \(count == 1 ? "value" : "values") (passwords, tokens, emails); --no-redact shows them."
    }

    @MainActor
    static func emit(_ collector: LogCollector, platform: DevicePlatform, device: String, json: Bool, write: (String) -> Void) {
        let entries = collector.entries
        if json {
            write(LogReport(platform: platform, device: device, entries: entries, truncated: collector.truncated, redacted: collector.redacted).jsonLine())
        } else if !entries.isEmpty {
            write(entries.map { LogText.format($0) }.joined(separator: "\n"))
        }
        if collector.truncated > 0 {
            print("Showing the newest \(entries.count) of \(entries.count + collector.truncated) entries; raise --max-lines or narrow with --grep.", to: &standardError)
        }
    }

    private static func list(_ flags: [String]) -> String {
        flags.count == 2 ? "\(flags[0]) and \(flags[1])" : flags.dropLast().joined(separator: ", ") + " and " + flags[flags.count - 1]
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
