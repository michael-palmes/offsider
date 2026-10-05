import Foundation

/// What `logs --json` prints: one compact object, or with `--follow` one compact entry per line.
public struct LogReport: Equatable, Sendable {
    public let platform: DevicePlatform
    public let device: String
    public let entries: [LogEntry]
    public let truncated: Int

    public init(platform: DevicePlatform, device: String, entries: [LogEntry], truncated: Int) {
        self.platform = platform
        self.device = device
        self.entries = entries
        self.truncated = truncated
    }

    /// `{"version":1,"platform":"ios","device":"…","entries":[…],"truncated":0}`.
    public func jsonLine() -> String {
        OrderedJSON.object([
            ("version", .integer(1)),
            ("platform", .string(platform.rawValue)),
            ("device", .string(device)),
            ("entries", .array(entries.map(Self.json))),
            ("truncated", .integer(truncated)),
        ]).rendered(compact: true)
    }

    /// `{"timestamp":"2026-10-02T12:47:18.399Z","level":"Info","process":"…","pid":1,"tag":"…","message":"…","raw":"…"}`; missing fields are null.
    public static func jsonLine(_ entry: LogEntry) -> String {
        json(entry).rendered(compact: true)
    }

    private static func json(_ entry: LogEntry) -> OrderedJSON {
        OrderedJSON.object([
            ("timestamp", .optional(entry.timestamp) { .string(timestamp($0)) }),
            ("level", .optional(entry.level, OrderedJSON.string)),
            ("process", .optional(entry.process, OrderedJSON.string)),
            ("pid", .optional(entry.pid, OrderedJSON.integer)),
            ("tag", .optional(entry.tag, OrderedJSON.string)),
            ("message", .string(entry.message)),
            ("raw", .optional(entry.raw, OrderedJSON.string)),
        ])
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}
