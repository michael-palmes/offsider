import Foundation

/// Masks `run start` applies to every capture in the run that asks for none of its own.
public struct RunMasks: Codable, Equatable, Sendable {
    public var secure: Bool
    public var emails: Bool
    public var ids: [String]

    public init(secure: Bool = false, emails: Bool = false, ids: [String] = []) {
        self.secure = secure
        self.emails = emails
        self.ids = ids
    }

    public var isEmpty: Bool { !secure && !emails && ids.isEmpty }

    public var plan: MaskPlan {
        MaskPlan(secure: secure, ids: ids, emails: emails)
    }
}

/// `runs/<ownerPid>-<ownerStartMicros>.json` under the private directory: which folder a session's run writes to.
public struct RunRecord: Codable, Equatable, Sendable {
    public static let maximumBytes = 64 * 1024

    public var version = 1
    public var dir: String
    public var label: String?
    public var startedAt: Date
    public var masks: RunMasks
    public var owner: ProcessIdentity

    public init(dir: String, label: String?, startedAt: Date, masks: RunMasks, owner: ProcessIdentity) {
        self.dir = dir
        self.label = label
        self.startedAt = startedAt
        self.masks = masks
        self.owner = owner
    }

    public static func fileName(for owner: ProcessIdentity) -> String {
        "\(owner.pid)-\(owner.startTime).json"
    }

    public func encoded() throws -> Data {
        try RunCoding.encoder.encode(self)
    }

    public init(data: Data) throws {
        self = try RunCoding.decoder.decode(RunRecord.self, from: data)
    }
}

/// `run.json` in the run's folder.
public struct RunState: Codable, Equatable, Sendable {
    public static let maximumBytes = 64 * 1024

    public var version = 1
    public var label: String?
    public var startedAt: Date
    public var stoppedAt: Date?
    /// The number the next file takes.
    public var next: Int
    /// `run-stop`, or `owner-exited` when the session that started it went away first.
    public var endedBy: String?
    public var masks: RunMasks

    public init(label: String?, startedAt: Date, stoppedAt: Date? = nil, next: Int = 1, endedBy: String? = nil, masks: RunMasks = RunMasks()) {
        self.label = label
        self.startedAt = startedAt
        self.stoppedAt = stoppedAt
        self.next = next
        self.endedBy = endedBy
        self.masks = masks
    }
}

enum RunCoding {
    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(RunClock.iso(date))
        }
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            guard let date = RunClock.parse(text) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "not an ISO 8601 time: \(text)"))
            }
            return date
        }
        return decoder
    }()
}

/// Local times for run files and summaries.
public enum RunClock {
    /// `2026-10-05T14:03:22.125+10:30`.
    public static func iso(_ date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = timeZone
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    public static func parse(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }

    /// `14.03.22` for file names, `14:03:22` for summaries.
    public static func clock(_ date: Date, separator: String, timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.hour, .minute, .second], from: date)
        return [parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0].map { String(format: "%02d", $0) }.joined(separator: separator)
    }

    /// `43 s`, `31 min 43 s` or `2 h 5 min`.
    public static func duration(from start: Date, to end: Date) -> String {
        let seconds = max(0, Int(end.timeIntervalSince(start).rounded()))
        if seconds < 60 { return "\(seconds) s" }
        if seconds < 3600 { return "\(seconds / 60) min \(seconds % 60) s" }
        return "\(seconds / 3600) h \(seconds % 3600 / 60) min"
    }
}
