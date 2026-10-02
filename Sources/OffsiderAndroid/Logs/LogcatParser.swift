import Foundation
import OffsiderCore

/// `logcat -v threadtime` lines as entries: `MM-DD HH:MM:SS.mmm  PID  TID L TAG: message`.
struct LogcatParser {
    /// Supplies the year logcat leaves out, and the zone its times are in.
    let reference: Date
    let timeZone: TimeZone
    private var previous: LogEntry?

    init(reference: Date = Date(), timeZone: TimeZone = .current) {
        self.reference = reference
        self.timeZone = timeZone
    }

    private static let header = try! NSRegularExpression(
        pattern: #"^(\d\d)-(\d\d)\s+(\d\d):(\d\d):(\d\d)\.(\d{3})\s+(\d+)\s+\d+\s+([VDIWEFAS])\s(.*?)\s*:(?: (.*))?$"#
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
                return LogEntry(message: line)
            }
            continuation.message = line
            return continuation
        }
        func group(_ index: Int) -> String? {
            Range(match.range(at: index), in: line).map { String(line[$0]) }
        }
        let numbers = (1...7).map { group($0).flatMap { Int($0) } ?? 0 }
        let entry = LogEntry(
            timestamp: date(month: numbers[0], day: numbers[1], hour: numbers[2], minute: numbers[3], second: numbers[4], millisecond: numbers[5]),
            level: group(8).flatMap { Self.levels[$0] },
            pid: numbers[6],
            tag: group(9).flatMap { $0.isEmpty ? nil : $0 },
            message: group(10) ?? ""
        )
        previous = entry
        return entry
    }

    /// In the reference year, or the year before when that would put the entry more than a day ahead.
    private func date(month: Int, day: Int, hour: Int, minute: Int, second: Int, millisecond: Int) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let year = calendar.component(.year, from: reference)
        func make(_ year: Int) -> Date? {
            calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second))?
                .addingTimeInterval(Double(millisecond) / 1000)
        }
        guard let date = make(year) else { return nil }
        return date.timeIntervalSince(reference) > 86_400 ? make(year - 1) : date
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
            words += ["-d", "-v", "threadtime", "-T", "\"$(($(date +%s)-\(duration.wholeSecondsRoundedUp))).000\""]
        case .since(let date):
            words += ["-d", "-v", "threadtime", "-T", AdbShellQuoting.quote(String(format: "%.3f", date.timeIntervalSince1970))]
        case .live:
            words += ["-v", "threadtime", "-T", "\"$(date +%s).000\""]
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
