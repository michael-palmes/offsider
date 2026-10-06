import Foundation
import OffsiderCore

/// `logcat -v threadtime -v epoch` lines as entries: `SECONDS.mmm  PID  TID L TAG: message`, with Unix times so no zone is involved.
struct LogcatParser {
    private var previous: LogEntry?

    private static let header = try! NSRegularExpression(
        pattern: #"^\s*(\d+)\.(\d{3,9})\s+(\d+)\s+\d+\s+([VDIWEFAS])\s(.*?)\s*:(?: (.*))?$"#
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
            level: group(4).flatMap { Self.levels[$0] },
            pid: group(3).flatMap { Int($0) },
            tag: group(5).flatMap { $0.isEmpty ? nil : $0 },
            message: group(6) ?? "",
            raw: line
        )
        previous = entry
        return entry
    }
}

/// The `logcat` shell commands `logs` runs on the device.
enum LogcatCommand {
    static let reactNativeFilters = ["ReactNativeJS:V", "ReactNative:V", "*:S"]

    /// History is a dump (`-d`) from a start time; live output starts at the device's own clock, so host and device need not agree.
    static func script(window: LogWindow, pid: Int?, reactNative: Bool) -> String {
        var words = ["logcat"]
        switch window {
        case .last(let duration):
            words += ["-d", "-v", "threadtime", "-v", "epoch", "-T", "\"$(($(date +%s)-\(duration.wholeSecondsRoundedUp))).000\""]
        case .since(let date):
            words += ["-d", "-v", "threadtime", "-v", "epoch", "-T", AdbShellQuoting.quote(String(format: "%.3f", date.timeIntervalSince1970))]
        case .live:
            words += ["-v", "threadtime", "-v", "epoch", "-T", "\"$(date +%s).000\""]
        }
        if let pid {
            words.append("--pid=\(pid)")
        }
        if reactNative {
            words += reactNativeFilters.map(AdbShellQuoting.quote)
        }
        return words.joined(separator: " ")
    }

    /// `pidof -s` prints the first matching pid, or nothing (status 1) when none runs.
    static func pidScript(for name: String) -> String {
        "pidof -s \(AdbShellQuoting.quote(name))"
    }
}
