import Foundation

/// A `logs` option the parser accepted but whose value is unusable; the message names the option and the fix.
public struct LogOptionError: Error, Equatable, Sendable {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }
}

/// Which stretch of the log `logs` reads.
public enum LogWindow: Equatable, Sendable {
    /// History ending now.
    case last(Duration)
    /// History from an absolute time to now.
    case since(Date)
    /// Output that arrives from now on, for `Duration` or, when nil, until interrupted.
    case live(Duration?)

    /// The longest `--last`: 365 days, in hours.
    public static let maximumLastHours = 8760
    /// The latest `--since`: the end of year 9999 UTC, the last time ISO 8601 can write with four digits.
    public static let latestSince = Date(timeIntervalSince1970: 253_402_300_799)

    /// `500ms`, `30s`, `2m` or `1h`; a bare number is seconds.
    public static func parseDuration(_ text: String) throws -> Duration {
        let trimmed = text.trimmingCharacters(in: .whitespaces).lowercased()
        let units: [(suffix: String, seconds: Double)] = [("ms", 0.001), ("s", 1), ("m", 60), ("h", 3600)]
        var number = trimmed
        var scale = 1.0
        if let unit = units.first(where: { trimmed.hasSuffix($0.suffix) }) {
            number = String(trimmed.dropLast(unit.suffix.count))
            scale = unit.seconds
        }
        guard let value = Double(number), value.isFinite, value > 0, !number.hasPrefix("+") else {
            throw LogOptionError("Invalid duration '\(text)'. Use a positive number with ms, s, m or h, such as 500ms, 30s, 2m or 1h.")
        }
        guard value * scale <= Double(maximumLastHours) * 3600 else {
            throw LogOptionError("Duration '\(text)' is too long. Use up to \(maximumLastHours)h (365 days).")
        }
        return .milliseconds(Int64((value * scale * 1000).rounded()))
    }

    /// ISO 8601 (with or without a zone, which then means the Mac's) or seconds since 1970.
    public static func parseTime(_ text: String, timeZone: TimeZone = .current) throws -> Date {
        let date = try parseAnyTime(text, timeZone: timeZone)
        guard date <= latestSince else {
            throw LogOptionError("--since time '\(text)' is too far in the future. Use a time up to 9999-12-31T23:59:59Z (253402300799 seconds since 1970).")
        }
        return date
    }

    private static func parseAnyTime(_ text: String, timeZone: TimeZone) throws -> Date {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if let seconds = Double(trimmed), seconds.isFinite, seconds >= 0 {
            return Date(timeIntervalSince1970: seconds)
        }
        let withZone = ISO8601DateFormatter()
        for options: ISO8601DateFormatter.Options in [[.withInternetDateTime, .withFractionalSeconds], [.withInternetDateTime]] {
            withZone.formatOptions = options
            if let date = withZone.date(from: trimmed.replacingOccurrences(of: " ", with: "T")) {
                return date
            }
        }
        let local = DateFormatter()
        local.locale = Locale(identifier: "en_US_POSIX")
        local.timeZone = timeZone
        for format in ["yyyy-MM-dd'T'HH:mm:ss.SSS", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm"] {
            local.dateFormat = format
            if let date = local.date(from: trimmed.replacingOccurrences(of: " ", with: "T")) {
                return date
            }
        }
        throw LogOptionError("Invalid --since time '\(text)'. Use ISO 8601, such as 2026-10-02T14:30:00 or 2026-10-02T14:30:00+10:00, or seconds since 1970.")
    }

    /// The oldest time an entry may have, for history windows.
    public func cutoff(now: Date) -> Date? {
        switch self {
        case .last(let duration): return now.addingTimeInterval(-duration.timeInterval)
        case .since(let date): return date
        case .live: return nil
        }
    }
}

/// Whose logs to read.
public enum LogSource: Equatable, Sendable {
    /// React Native's own log alone.
    public static let reactNative = LogSource.reactNative(app: nil)

    case all
    /// React Native's JavaScript console and native messages, and with an app, everything that app logs too.
    case reactNative(app: String?)
    /// An app by bundle identifier (iOS) or package (Android).
    case app(String)
    /// A process by name.
    case process(String)
}

public struct LogQuery: Equatable, Sendable {
    public var source: LogSource
    public var window: LogWindow
    /// An extra NSPredicate, combined with the source by AND; iOS only.
    public var predicate: String?

    public init(source: LogSource = .all, window: LogWindow, predicate: String? = nil) {
        self.source = source
        self.window = window
        self.predicate = predicate
    }
}

public struct LogEntry: Equatable, Sendable {
    public var timestamp: Date?
    public var level: String?
    public var process: String?
    public var pid: Int?
    /// The Android tag, or the iOS subsystem and category.
    public var tag: String?
    public var message: String
    /// The source line as the device wrote it: a logcat line, or the iOS event message with its colour codes.
    public var raw: String?

    public init(timestamp: Date? = nil, level: String? = nil, process: String? = nil, pid: Int? = nil, tag: String? = nil, message: String, raw: String? = nil) {
        self.timestamp = timestamp
        self.level = level
        self.process = process
        self.pid = pid
        self.tag = tag
        self.message = message
        self.raw = raw
    }
}

/// What a backend learnt while reading that the reader should hear about.
public enum LogNote: Equatable, Sendable {
    /// The device's clock minus this Mac's, in whole seconds, when they differ by more than `LogClock.skewThreshold`.
    case clockSkew(seconds: Int)
}

/// Comparing a device's clock with this Mac's, whose times `--since` is given in.
public enum LogClock {
    public static let skewThreshold = 3

    /// The skew when it is past the threshold, from the device's `date +%s` read at `hostNow`.
    public static func skew(deviceSeconds: Int, hostNow: Date) -> Int? {
        let seconds = deviceSeconds - Int(hostNow.timeIntervalSince1970.rounded())
        return abs(seconds) > skewThreshold ? seconds : nil
    }

    public static func note(_ seconds: Int, device: String) -> String {
        let direction = seconds > 0 ? "ahead of" : "behind"
        return "Note: \(device)'s clock is \(abs(seconds)) s \(direction) this Mac's. Log times are the device's own; --last and --since were counted back from its clock."
    }
}

/// Optional capability: reading the device's log for `logs`.
@MainActor
public protocol LogReading: DeviceBackend {
    /// Delivers entries oldest first, and notes as they come up; returns when the window ends or the task is cancelled.
    func readLogs(_ query: LogQuery, on id: DeviceID, onEntry: @escaping @MainActor (LogEntry) -> Void, onNote: @escaping @MainActor (LogNote) -> Void) async throws
}

extension LogReading {
    public func readLogs(_ query: LogQuery, on id: DeviceID, onEntry: @escaping @MainActor (LogEntry) -> Void) async throws {
        try await readLogs(query, on: id, onEntry: onEntry, onNote: { _ in })
    }
}

extension Duration {
    public var timeInterval: TimeInterval {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }

    /// Whole seconds, rounded up, at least 1: what `log show --last` and `logcat -T` take.
    public var wholeSecondsRoundedUp: Int {
        max(1, Int(timeInterval.rounded(.up)))
    }
}
