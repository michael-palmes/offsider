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
        are removed unless --raw. Exits 0 even when nothing matches. On iOS this reads the simulator's unified log; \
        on Android, logcat.
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

    @Option(help: ArgumentHelp("Entries from this long ago until now: 500ms, 30s, 2m, 1h, or bare seconds (default 30s).", valueName: "duration"))
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

    @Flag(help: "Keep ANSI colour codes in messages.")
    var raw = false

    @Flag(name: .customLong("json"), help: "Print one JSON object to stdout; human text goes to stderr.")
    var json = false

    @OptionGroup
    var deviceOption: DeviceOption

    static let defaultLast = "30s"

    func validate() throws {
        try Self.check { try query() }
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
        try LogCollector(maxLines: follow ? 0 : maxLines, grep: grep, keepsANSI: raw, retainsEntries: !follow)
    }

    func run() async throws {
        let logger = OffsiderLogger()
        try await read(from: try await DeviceRouter.route(deviceOption.id, logger: logger))
    }

    @MainActor
    func read(from route: DeviceRouter.Route) async throws {
        let backend = route.backend
        try await backend.prepare()
        let booted = try await backend.requireBootedDevice(route.device)
        guard let reader = backend as? any LogReading else {
            throw CLIError(errorDescription: "logs is not available for \(booted.id.platform.rawValue) devices in this build.")
        }
        let query = try Self.options { try self.query() }
        let sink = LogSink(try Self.options { try self.collector() })

        let follow = self.follow
        let json = self.json
        let reading = Task { @MainActor in
            try await reader.readLogs(query, on: booted.id) { entry in
                guard let shown = sink.collector.add(entry), follow else { return }
                print(json ? LogReport.jsonLine(shown) : LogText.format(shown))
                fflush(stdout)
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
        guard !follow else { return }
        Self.emit(sink.collector, platform: booted.id.platform, device: booted.id.rawValue, json: json)
    }

    static func emit(_ collector: LogCollector, platform: DevicePlatform, device: String, json: Bool) {
        let entries = collector.entries
        if json {
            print(LogReport(platform: platform, device: device, entries: entries, truncated: collector.truncated).jsonLine())
        } else if !entries.isEmpty {
            print(entries.map { LogText.format($0) }.joined(separator: "\n"))
        }
        if collector.truncated > 0 {
            fflush(stdout)
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
            throw CLIError(errorDescription: error.message)
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
