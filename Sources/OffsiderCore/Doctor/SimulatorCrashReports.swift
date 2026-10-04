import Foundation

/// One crash a simulator process reported to macOS, read from a `.ips` file's header and top-level keys.
public struct SimulatorCrash: Equatable, Sendable {
    public let udid: String
    public let process: String
    public let timestamp: Date

    public init(udid: String, process: String, timestamp: Date) {
        self.udid = udid
        self.process = process
        self.timestamp = timestamp
    }
}

public enum SimulatorCrashReports {
    public static let window: TimeInterval = 600
    public static let coalitionPrefix = "com.apple.CoreSimulator.SimDevice."
    /// The keys doctor reads sit in the first few kilobytes, before any thread or frame data.
    public static let prefixBytes = 16 * 1024

    /// Parses the start of a `.ips` report; nil for reports from outside a simulator or ones without the keys.
    public static func parse(_ prefix: String, modified: Date) -> SimulatorCrash? {
        guard prefix.contains(coalitionPrefix) else { return nil }
        let lines = prefix.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        guard lines.count == 2 else { return nil }
        let header = (try? JSONSerialization.jsonObject(with: Data(lines[0].utf8))) as? [String: Any]
        let body = String(lines[1])
        guard
            let coalition = topLevelString("coalitionName", in: body),
            coalition.hasPrefix(coalitionPrefix),
            let process = topLevelString("procName", in: body) ?? header?["app_name"] as? String
        else { return nil }
        let udid = String(coalition.dropFirst(coalitionPrefix.count)).uppercased()
        guard UUID(uuidString: udid) != nil else { return nil }
        let timestamp = (header?["timestamp"] as? String).flatMap(parseTimestamp) ?? modified
        return SimulatorCrash(udid: udid, process: process, timestamp: timestamp)
    }

    /// Crashes within `window` of `now`, so stale or future-dated reports never count.
    public static func recent(_ crashes: [SimulatorCrash], now: Date) -> [SimulatorCrash] {
        crashes.filter { now.timeIntervalSince($0.timestamp) <= window && $0.timestamp.timeIntervalSince(now) <= 60 }
    }

    /// Crash counts per process, most first, then by name.
    public static func counts(_ crashes: [SimulatorCrash], udid: String) -> [(process: String, count: Int)] {
        Dictionary(grouping: crashes.filter { $0.udid == udid.uppercased() }, by: \.process)
            .map { (process: $0.key, count: $0.value.count) }
            .sorted { ($1.count, $0.process) < ($0.count, $1.process) }
    }

    static func topLevelString(_ key: String, in body: String) -> String? {
        guard let keyRange = body.range(of: "\"\(key)\"") else { return nil }
        var rest = body[keyRange.upperBound...].drop { $0 == " " }
        guard rest.first == ":" else { return nil }
        rest = rest.dropFirst().drop { $0 == " " }
        guard rest.first == "\"" else { return nil }
        let value = rest.dropFirst().prefix { $0 != "\"" && $0 != "\n" }
        return value.isEmpty ? nil : String(value)
    }

    static func parseTimestamp(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SS Z"
        return formatter.date(from: text)
    }
}

extension DoctorRules {
    /// `crashes` are the recent reports for every simulator; only `udid`'s count.
    public static func crashLoop(_ crashes: [SimulatorCrash], udid: String) -> Verdict {
        let counts = SimulatorCrashReports.counts(crashes, udid: udid)
        guard let worst = counts.first?.count else {
            return (.pass, "No crashes in the last 10 minutes", nil)
        }
        let detail = counts.map(crashSummary).joined(separator: "; ")
        guard worst >= 2 else {
            return (.pass, detail, nil)
        }
        guard worst >= loopThreshold else {
            return (.warn, detail, "A few crashes after boot or under host load are common; run doctor again if \"quit unexpectedly\" dialogs keep appearing.")
        }
        return (.fail, detail, eraseHint(udid))
    }

    /// A process that crashed this often in ten minutes is being restarted in a loop; busy hosts see two or three.
    public static let loopThreshold = 5

    /// Every simulator with `loopThreshold` or more crashes of one process; `names` maps known UDIDs to simulator names.
    public static func crashLoops(_ crashes: [SimulatorCrash], names: [String: String]) -> Verdict {
        let looping = Set(crashes.map(\.udid)).sorted().compactMap { udid -> String? in
            let counts = SimulatorCrashReports.counts(crashes, udid: udid).filter { $0.count >= loopThreshold }
            guard !counts.isEmpty else { return nil }
            let label = names[udid].map { "\($0) (\(udid))" } ?? udid
            return "\(label): \(counts.map(crashSummary).joined(separator: ", "))"
        }
        guard !looping.isEmpty else {
            return (.pass, "No simulator crash loops in the last 10 minutes", nil)
        }
        return (
            .warn,
            looping.joined(separator: "; "),
            "Run offsider doctor --device <UDID> for the fix; erasing a simulator removes its apps and settings."
        )
    }

    static func crashSummary(_ entry: (process: String, count: Int)) -> String {
        "\(entry.process) crashed \(entry.count) \(entry.count == 1 ? "time" : "times") in the last 10 minutes"
    }

    static func eraseHint(_ udid: String) -> String {
        "The simulator is in a crash loop. Erase it (this removes its apps and settings): xcrun simctl shutdown \(udid) && xcrun simctl erase \(udid)"
    }
}
