import Foundation
import OffsiderCore

/// `--rn --app`: React Native's tags, plus every line from the app's user ID, which survives a restart where a pid would not.
struct LogcatAppFilter: Equatable {
    static let reactNativeTags: Set<String> = ["ReactNativeJS", "ReactNative"]

    let package: String
    let uid: String

    func keeps(_ entry: LogEntry, uid: String?) -> Bool {
        uid == self.uid || entry.tag.map(Self.reactNativeTags.contains) == true
    }

    /// The package's user ID from `cmd package list packages -U <package>`, which also lists packages it only prefixes.
    static func uid(of package: String, in listing: [String]) -> String? {
        let prefix = "package:\(package) uid:"
        return listing.lazy
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { $0.hasPrefix(prefix) }
            .map { String($0.dropFirst(prefix.count).prefix { $0.isNumber }) }
            .flatMap { $0.isEmpty ? nil : $0 }
    }
}

/// One `LogcatCommand.script`'s output read line by line: its preamble up to the marker, then the entries the source keeps.
struct LogcatStream {
    let source: LogSource
    let serial: String
    private(set) var pid: Int?
    private(set) var filter: LogcatAppFilter?
    /// Set once from the device's clock line when it is past `LogClock.skewThreshold`; the reader takes it.
    var note: LogNote?
    private(set) var started = false
    private var listing: [String] = []
    private var parser = LogcatParser()

    init(source: LogSource, serial: String) {
        self.source = source
        self.serial = serial
    }

    /// The entry a line adds, nil for the preamble, separators and lines the source leaves out; `now` is this Mac's clock.
    mutating func consume(_ line: String, now: Date = Date()) throws -> LogEntry? {
        guard started else {
            try readPreamble(line.trimmingCharacters(in: .whitespacesAndNewlines), now: now)
            return nil
        }
        guard var entry = parser.parse(line) else { return nil }
        switch source {
        case .reactNative(let package?):
            guard let filter, filter.keeps(entry, uid: parser.lastUID) else { return nil }
            if parser.lastUID == filter.uid { entry.process = package }
        case .app(let name), .process(let name):
            if let pid, entry.pid == pid { entry.process = name }
        case .all, .reactNative(nil):
            break
        }
        return entry
    }

    private mutating func readPreamble(_ line: String, now: Date) throws {
        if line.hasPrefix(LogcatCommand.clockMarker) {
            note = Int(line.dropFirst(LogcatCommand.clockMarker.count))
                .flatMap { LogClock.skew(deviceSeconds: $0, hostNow: now) }
                .map { .clockSkew(seconds: $0) }
            return
        }
        if line == LogcatCommand.notRunningMarker {
            throw Self.notRunning(source, serial: serial)
        }
        if line.hasPrefix(LogcatCommand.pidMarker) {
            pid = Int(line.dropFirst(LogcatCommand.pidMarker.count))
            return
        }
        guard line == LogcatCommand.startMarker else {
            listing.append(line)
            return
        }
        if case .reactNative(let package?) = source {
            guard let uid = LogcatAppFilter.uid(of: package, in: listing) else {
                throw AndroidError(.appNotInstalled, "\(package) is not installed on \(serial). Install it, or drop --app to read React Native's log alone.")
            }
            filter = LogcatAppFilter(package: package, uid: uid)
        }
        started = true
    }

    static func notRunning(_ source: LogSource, serial: String) -> AndroidError {
        let (noun, flag, name): (String, String, String)
        switch source {
        case .process(let process): (noun, flag, name) = ("Process", "--process", process)
        case .app(let app): (noun, flag, name) = ("App", "--app", app)
        default: (noun, flag, name) = ("App", "--app", "the app")
        }
        return AndroidError(.adbCommandFailed, "\(noun) \(name) is not running on \(serial). Launch it, or drop \(flag) to read all logs.")
    }
}
