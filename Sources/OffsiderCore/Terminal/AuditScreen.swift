import Foundation

/// What `devices status --audit` shows: the newest audit records, with each device named where the allow-list still knows it.
public enum AuditScreen {
    public static let title = "Physical device audit trail"
    public static let nothing = "Nothing recorded yet."

    /// The allow-list's name for a hashed device key; nil once the device is gone from the list.
    static func names(_ list: DeviceAllowList) -> [String: String] {
        var names: [String: String] = [:]
        for entry in list.entries { names[AuditRecord.deviceKey(platform: entry.platform, key: entry.key)] = AccessStatusScreen.name(entry) }
        return names
    }

    /// `2026-11-22 14:05` in the person's time zone.
    static func when(_ date: Date, timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        return unsafe String(format: "%04d-%02d-%02d %02d:%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0, parts.hour ?? 0, parts.minute ?? 0)
    }

    /// `, exit 5, condition_not_met` after a word; empty for exit 0, and `, ended early` when the process left before it had one.
    static func ending(_ record: AuditRecord) -> String {
        guard let exit = record.exit else { return ", ended early" }
        return exit == 0 ? "" : ", exit \(exit)" + (record.reason.map { ", \($0)" } ?? "")
    }

    /// `ran`, `ran, exit 5, condition_not_met`, `refused, expired`, `allowed until removed`: what a person reads in the last column.
    static func result(_ record: AuditRecord) -> String {
        switch record.outcome {
        case .ran: return "ran" + ending(record)
        case .refused: return "refused, " + (record.refusal ?? record.reason ?? "by policy")
        case .allowed: return "allowed " + (record.expires.map { "until \(ProcessStamp.timestamp($0))" } ?? "until removed")
        case .withdrawn: return "withdrawn" + (record.refusal.map { ", \($0)" } ?? "")
        case .sessionStarted: return "session started"
        case .sessionStopped: return "session stopped" + (record.refusal.map { ", \($0)" } ?? "")
        case .registration: return "runner build with registration" + ending(record)
        case .unlockCodeSaved: return "unlock code saved"
        }
    }

    static func status(_ record: AuditRecord) -> RowStatus {
        record.outcome != .refused && record.exit == 0 || [.allowed, .withdrawn, .sessionStarted].contains(record.outcome) ? .ok : .warn
    }

    public static func table(_ records: [AuditRecord], list: DeviceAllowList, timeZone: TimeZone) -> Table {
        let names = names(list)
        let rows = records.map { record in
            Table.Row([
                Table.Cell(ProcessStamp.timestamp(record.time), person: when(record.time, timeZone: timeZone)),
                Table.Cell(record.device, person: names[record.device]),
                Table.Cell(record.platform.rawValue),
                Table.Cell(record.command),
                Table.Cell(record.outcome.rawValue, person: result(record)),
                Table.Cell(record.exit.map { String($0) } ?? "-"),
                Table.Cell(record.reason ?? "-"),
                Table.Cell(record.refusal ?? "-"),
                Table.Cell(record.app ?? "-"),
            ], status: status(record))
        }
        return Table(columns: [
            Table.Column(agent: "TIME", person: 0, fit: .whole, tone: .dim),
            Table.Column(agent: "DEVICE", person: 1, fit: .cut(min: 10)),
            Table.Column(agent: "PLATFORM", person: nil),
            Table.Column(agent: "COMMAND", person: 2, fit: .whole),
            Table.Column(agent: "OUTCOME", person: 3, fit: .cut(min: 12), tone: .dim),
            Table.Column(agent: "EXIT", person: nil),
            Table.Column(agent: "REASON", person: nil),
            Table.Column(agent: "REFUSAL", person: nil),
            Table.Column(agent: "APP", person: 4, fit: .optional(priority: 1), tone: .dim),
        ], rows: rows)
    }

    /// A person's table under one header; an agent reads the path, then the same rows as plain columns.
    public static func page(_ records: [AuditRecord], list: DeviceAllowList, path: String, timeZone: TimeZone) -> Page {
        guard !records.isEmpty else {
            return Page([.person([.header(Header(.logs, title, ["empty"])), .prose(nothing)]), .agent("Audit trail: \(path) holds no records.\n")])
        }
        let shown = "\(records.count) newest"
        return Page([
            .person([.header(Header(.logs, title, [shown]))]),
            .agent("Audit trail: \(path), \(shown), oldest first.\n"),
            .table(table(records, list: list, timeZone: timeZone)),
        ])
    }

    /// The `audit` member `devices status --audit --json` adds: each record as the file holds it, without its chain link.
    static func json(_ records: [AuditRecord]) -> OrderedJSON {
        .array(records.map { $0.json(prev: nil) })
    }
}
