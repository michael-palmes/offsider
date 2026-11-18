import Darwin
import Foundation

/// A process's start time from the kernel, which survives pid reuse checks: a reused pid starts later.
public enum ProcessStartTime {
    /// Seconds and microseconds since 1970, or nil when the process has gone or belongs to another user.
    public static func of(_ pid: Int32) -> (seconds: Int, microseconds: Int)? {
        guard pid > 0 else { return nil }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard unsafe proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return (Int(info.pbi_start_tvsec), Int(info.pbi_start_tvusec))
    }

    public static func date(of pid: Int32) -> Date? {
        of(pid).map { Date(timeIntervalSince1970: TimeInterval($0.seconds) + TimeInterval($0.microseconds) / 1_000_000) }
    }
}

/// A process and when it started, as `devices --json` reports it.
public struct ProcessStamp: Equatable, Sendable {
    public let pid: Int32
    public let startedAt: Date

    public init(pid: Int32, startedAt: Date) {
        self.pid = pid
        self.startedAt = startedAt
    }

    /// UTC to the second, rounded down: `2026-10-05T03:12:44Z`.
    public static func timestamp(_ date: Date) -> String {
        Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.down)).formatted(.iso8601)
    }

    /// `pid 4242, started 14 min ago at 11:52:33`: the start as an age and a local time, with the date once it is over a day old.
    public func summary(now: Date, timeZone: TimeZone = .current) -> String {
        let age = max(0, Int(now.timeIntervalSince(startedAt)))
        let ago = switch age {
        case ..<60: "\(age) s ago"
        case ..<3600: "\(age / 60) min ago"
        case ..<172_800: "\(age / 3600) h ago"
        default: "\(age / 86_400) days ago"
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = age < 86_400 ? "HH:mm:ss" : "d MMM HH:mm"
        return "pid \(pid), started \(ago) at \(formatter.string(from: startedAt))"
    }

    /// The date an ISO 8601 timestamp names, such as one `timestamp` wrote; nil for anything else.
    public static func date(fromTimestamp text: String) -> Date? {
        try? Date(text, strategy: .iso8601)
    }
}
