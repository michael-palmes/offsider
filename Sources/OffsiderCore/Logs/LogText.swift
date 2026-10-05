import Foundation

/// Pure text work for `logs`: ANSI stripping, iOS predicates and `log` arguments, ndjson parsing and the human line.
public enum LogText {
    public static let reactNativeSubsystem = "com.facebook.react.log"

    // MARK: ANSI

    private static let realEscape = try! NSRegularExpression(pattern: #"\x{1B}\[[0-?]*[ -/]*[@-~]"#)
    private static let escapedEscape = try! NSRegularExpression(pattern: #"(?:\\u001[bB]|\\x1[bB]|\\033|\\e)\[[0-9;]*m"#)

    /// Removes real CSI sequences and SGR colour codes written out as `\u001b[`, `\x1b[`, `\033[` or `\e[`.
    public static func stripANSI(_ text: String) -> String {
        var result = text
        if result.contains("\u{1B}") {
            result = realEscape.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "")
        }
        if result.contains("\\") {
            result = escapedEscape.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "")
        }
        return result
    }

    // MARK: iOS

    /// The NSPredicate for `source` (with `executable` resolved for `.app`), ANDed with `extra`; nil reads everything.
    public static func iosPredicate(for source: LogSource, executable: String?, extra: String? = nil) -> String? {
        let base: String?
        switch source {
        case .all:
            base = nil
        case .reactNative:
            base = "subsystem == \(quoted(reactNativeSubsystem))"
        case .app(let bundleID):
            base = "process == \(quoted(executable ?? bundleID))"
        case .process(let name):
            base = "process == \(quoted(name))"
        }
        let extra = extra?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        switch (base, extra) {
        case (nil, nil): return nil
        case (let base?, nil): return base
        case (nil, let extra?): return extra
        case (let base?, let extra?): return "(\(base)) AND (\(extra))"
        }
    }

    /// Arguments for the simulator's `log`: `show` for history, `stream` for live output, always ndjson with info and debug.
    public static func iosLogArguments(window: LogWindow, predicate: String?) -> [String] {
        var arguments: [String]
        switch window {
        case .last(let duration):
            arguments = ["show", "--last", "\(duration.wholeSecondsRoundedUp)s"]
        case .since(let date):
            arguments = ["show", "--start", "@\(Int(date.timeIntervalSince1970.rounded(.down)))"]
        case .live:
            arguments = ["stream"]
        }
        arguments += ["--style", "ndjson", "--info", "--debug"]
        if let predicate {
            arguments += ["--predicate", predicate]
        }
        return arguments
    }

    /// One `log --style ndjson` line as an entry; nil for activity events, the closing count and anything not JSON.
    public static func parseIOSNDJSON(_ line: String) -> LogEntry? {
        guard line.hasPrefix("{"),
              let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              object["eventType"] as? String == "logEvent",
              let message = object["eventMessage"] as? String else {
            return nil
        }
        let subsystem = (object["subsystem"] as? String)?.nilIfEmpty
        let category = (object["category"] as? String)?.nilIfEmpty
        let tag: String?
        if subsystem == reactNativeSubsystem {
            tag = category ?? subsystem
        } else if let subsystem {
            tag = category.map { "\(subsystem):\($0)" } ?? subsystem
        } else {
            tag = category
        }
        let imagePath = (object["processImagePath"] as? String)?.nilIfEmpty
        return LogEntry(
            timestamp: (object["timestamp"] as? String).flatMap(parseIOSTimestamp),
            level: (object["messageType"] as? String)?.nilIfEmpty,
            process: imagePath.map { ($0 as NSString).lastPathComponent },
            pid: (object["processID"] as? NSNumber)?.intValue,
            tag: tag,
            message: message,
            raw: message
        )
    }

    /// `2026-10-02 22:17:18.399020+0930`, as `log` prints it.
    static func parseIOSTimestamp(_ text: String) -> Date? {
        let scalars = Array(text.utf8)
        guard scalars.count >= 24 else { return nil }
        func number(_ range: Range<Int>) -> Int? {
            guard range.upperBound <= scalars.count else { return nil }
            var value = 0
            for byte in scalars[range] {
                guard (48...57).contains(byte) else { return nil }
                value = value * 10 + Int(byte - 48)
            }
            return value
        }
        guard let year = number(0..<4), let month = number(5..<7), let day = number(8..<10),
              let hour = number(11..<13), let minute = number(14..<16), let second = number(17..<19) else {
            return nil
        }
        var index = 19
        var fraction = 0.0
        if index < scalars.count, scalars[index] == UInt8(ascii: ".") {
            index += 1
            var scale = 0.1
            while index < scalars.count, (48...57).contains(scalars[index]) {
                fraction += Double(scalars[index] - 48) * scale
                scale /= 10
                index += 1
            }
        }
        guard index + 5 <= scalars.count, let sign = [UInt8(ascii: "+"): 1, UInt8(ascii: "-"): -1][scalars[index]],
              let zoneHours = number(index + 1..<index + 3), let zoneMinutes = number(index + 3..<index + 5),
              let zone = TimeZone(secondsFromGMT: sign * (zoneHours * 3600 + zoneMinutes * 60)) else {
            return nil
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let components = DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second)
        return calendar.date(from: components)?.addingTimeInterval(fraction)
    }

    // MARK: Output

    /// `HH:MM:SS.mmm Level process[pid] tag: message`, leaving out what the entry lacks.
    public static func format(_ entry: LogEntry, timeZone: TimeZone = .current) -> String {
        var parts: [String] = []
        if let timestamp = entry.timestamp {
            parts.append(clockTime(timestamp, timeZone: timeZone))
        }
        if let level = entry.level {
            parts.append(level.padding(toLength: max(level.count, 7), withPad: " ", startingAt: 0))
        }
        switch (entry.process, entry.pid) {
        case (let process?, let pid?): parts.append("\(process)[\(pid)]")
        case (let process?, nil): parts.append(process)
        case (nil, let pid?): parts.append("[\(pid)]")
        case (nil, nil): break
        }
        if let tag = entry.tag {
            parts.append("\(tag):")
        }
        parts.append(entry.message)
        return parts.joined(separator: " ")
    }

    static func clockTime(_ date: Date, timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let components = calendar.dateComponents([.hour, .minute, .second, .nanosecond], from: date)
        let milliseconds = min(999, (components.nanosecond ?? 0) / 1_000_000)
        return String(format: "%02d:%02d:%02d.%03d", components.hour ?? 0, components.minute ?? 0, components.second ?? 0, milliseconds)
    }

    private static func quoted(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}

extension String {
    fileprivate var nilIfEmpty: String? { isEmpty ? nil : self }
}
