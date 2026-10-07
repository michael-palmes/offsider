import Foundation
import OffsiderCore

/// `logcat -v threadtime -v epoch` lines as entries: `SECONDS.mmm [UID] PID TID L TAG: message`, with Unix times so no zone is involved.
struct LogcatParser {
    private var previous: LogEntry?
    /// The user ID column `-v uid` adds, for the last line read; a continuation keeps its entry's.
    private(set) var lastUID: String?

    private static let header = try! NSRegularExpression(
        pattern: #"^\s*(\d+)\.(\d{3,9})\s+(?:(\S+)\s+)?(\d+)\s+\d+\s+([VDIWEFAS])\s(.*?)\s*:(?: (.*))?$"#
    )

    static let levels: [String: String] = [
        "V": "Verbose", "D": "Debug", "I": "Info", "W": "Warning", "E": "Error", "F": "Fatal", "A": "Fatal", "S": "Silent",
    ]

    /// The entry for one line; a line without a header continues the previous entry's message, and separators are nil.
    mutating func parse(_ line: String) -> LogEntry? {
        let line = line.trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
        if line.isEmpty || line.hasPrefix("--------- ") {
            return nil
        }
        guard let match = Self.header.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) else {
            guard var continuation = previous else {
                return LogEntry(message: line, raw: line)
            }
            continuation.message = line
            continuation.raw = line
            return continuation
        }
        func group(_ index: Int) -> String? {
            Range(match.range(at: index), in: line).map { String(line[$0]) }
        }
        let timestamp = group(1).flatMap { seconds in group(2).flatMap { Double("\(seconds).\($0)") } }
        let entry = LogEntry(
            timestamp: timestamp.map { Date(timeIntervalSince1970: $0) },
            level: group(5).flatMap { Self.levels[$0] },
            pid: group(4).flatMap { Int($0) },
            tag: group(6).flatMap { $0.isEmpty ? nil : $0 },
            message: group(7) ?? "",
            raw: line
        )
        lastUID = group(3)
        previous = entry
        return entry
    }
}

/// The one shell script `logs` runs on the device: what the source needs first, a marker line, then `logcat`.
enum LogcatCommand {
    static let reactNativeFilters = ["ReactNativeJS:V", "ReactNative:V", "*:S"]
    static let startMarker = "offsider-logcat"
    static let clockMarker = "offsider-clock "
    static let pidMarker = "offsider-pid "
    static let notRunningMarker = "offsider-not-running"

    /// Device clock first (skew); `--app`/`--process` find the pid or stop, `--rn --app` the uid; `--since` counts back from this Mac's `now`.
    static func script(window: LogWindow, source: LogSource, now: Date = Date()) -> String {
        var preamble = ["echo \"\(clockMarker)$(date +%s)\""]
        var pid: String?
        switch source {
        case .app(let name), .process(let name):
            preamble.append("p=$(\(pidScript(for: name))) || { echo \(notRunningMarker); exit 3; }")
            preamble.append("echo \"\(pidMarker)$p\"")
            pid = "$p"
        case .reactNative(let package?):
            preamble.append("cmd package list packages -U \(AdbShellQuoting.quote(package))")
        case .all, .reactNative(nil):
            break
        }
        preamble.append("echo \(startMarker)")
        var logcat = logcatWords(window: window, now: now)
        if case .reactNative(_?) = source { logcat += ["-v", "uid"] }
        if let pid { logcat.append("--pid=\(pid)") }
        if source == .reactNative(app: nil) { logcat += reactNativeFilters.map(AdbShellQuoting.quote) }
        return (preamble + [logcat.joined(separator: " ")]).joined(separator: "; ")
    }

    /// History is a dump (`-d`) counted back from the device's own clock, as is live output, so a skewed clock still reads the right stretch.
    private static func logcatWords(window: LogWindow, now: Date) -> [String] {
        var words = ["logcat"]
        switch window {
        case .last(let duration):
            words += ["-d", "-v", "threadtime", "-v", "epoch", "-T", "\"$(($(date +%s)-\(duration.wholeSecondsRoundedUp))).000\""]
        case .since(let date):
            let back = max(0, Int(now.timeIntervalSince(date).rounded(.up)))
            words += ["-d", "-v", "threadtime", "-v", "epoch", "-T", "\"$(($(date +%s)-\(back))).000\""]
        case .live:
            words += ["-v", "threadtime", "-v", "epoch", "-T", "\"$(date +%s).000\""]
        }
        return words
    }

    /// `pidof -s` prints the first matching pid, or nothing (status 1) when none runs.
    static func pidScript(for name: String) -> String {
        "pidof -s \(AdbShellQuoting.quote(name))"
    }
}
