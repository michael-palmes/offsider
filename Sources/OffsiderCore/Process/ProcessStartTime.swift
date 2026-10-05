import Darwin
import Foundation

/// A process's start time from the kernel, which survives pid reuse checks: a reused pid starts later.
public enum ProcessStartTime {
    /// Seconds and microseconds since 1970, or nil when the process has gone or belongs to another user.
    public static func of(_ pid: Int32) -> (seconds: Int, microseconds: Int)? {
        guard pid > 0 else { return nil }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return (Int(info.pbi_start_tvsec), Int(info.pbi_start_tvusec))
    }

    public static func date(of pid: Int32) -> Date? {
        of(pid).map { Date(timeIntervalSince1970: TimeInterval($0.seconds) + TimeInterval($0.microseconds) / 1_000_000) }
    }
}

/// A process and when it started, as `list-devices --json` reports it.
public struct ProcessStamp: Equatable, Sendable {
    public let pid: Int32
    public let startedAt: Date

    public init(pid: Int32, startedAt: Date) {
        self.pid = pid
        self.startedAt = startedAt
    }

    /// UTC to the second: `2026-10-05T03:12:44Z`.
    public static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}
