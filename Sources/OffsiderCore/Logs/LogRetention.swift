import Foundation

/// The iOS unified log keeps Info and Debug entries for a shorter time than Default and Error ones.
public struct LogRetention: Equatable, Sendable {
    /// How far past the window's start the oldest Info or Debug entry must be, with older Default or Error entries, to warn.
    public static let gap: TimeInterval = 10

    public private(set) var oldestShortLived: Date?
    public private(set) var oldestKept: Date?

    public init() {}

    /// Notes one entry as read, before `--grep`, so a filter cannot make the gap.
    public mutating func add(_ entry: LogEntry) {
        guard let timestamp = entry.timestamp, let level = entry.level?.lowercased() else { return }
        switch level {
        case "info", "debug":
            oldestShortLived = min(oldestShortLived ?? timestamp, timestamp)
        case "default", "error", "fault":
            oldestKept = min(oldestKept ?? timestamp, timestamp)
        default:
            break
        }
    }

    /// The stderr warning when Info and Debug entries begin well after `cutoff` though older Default or Error entries were read.
    public func warning(cutoff: Date, timeZone: TimeZone = .current) -> String? {
        guard let shortLived = oldestShortLived, let kept = oldestKept,
              shortLived.timeIntervalSince(cutoff) > Self.gap, shortLived.timeIntervalSince(kept) > Self.gap else { return nil }
        let late = Int(shortLived.timeIntervalSince(cutoff).rounded())
        let time = LogText.clockTime(shortLived, timeZone: timeZone) + LogText.offset(at: shortLived, in: timeZone)
        return "Warning: the oldest Info or Debug entry is from \(time), \(late) s after the window starts, while Default and Error entries go back further: iOS keeps Info and Debug entries only briefly. Read sooner after the action, or collect live with --duration or --follow."
    }
}
