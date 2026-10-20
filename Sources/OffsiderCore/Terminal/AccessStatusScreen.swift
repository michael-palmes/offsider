import Foundation

/// What `device-access status` shows a person: a header that counts the devices agents may control now, a row for each,
/// a warning when the managed policy or a broken list refuses devices, and the commands to change it.
public enum AccessStatusScreen {
    public static let title = "Phones and tablets agents may control"
    public static let nothingAllowed = "Nothing allowed yet."
    public static let managedBlocksAll = "Managed policy blocks every device."
    public static let managedBlocksSome = "Managed policy blocks some devices."
    public static let listChanged = "List changed outside Offsider. Allow again."
    public static let listUnreadable = "List unreadable. Allow again."
    public static let allowCommand = "offsider device-access allow"

    public static func removeCommand(_ key: String) -> String { "offsider device-access remove --device \(PromptScreen.visible(key))" }

    /// `any app · until 22:14`, `com.example.app · until removed`, with `· team ABCDE12345` when `team` is on and the entry has one.
    public static func detail(_ entry: DeviceAllowance, now: Date, timeZone: TimeZone, team: Bool, style: TerminalStyle) -> String {
        ([apps(entry), until(entry, now: now, timeZone: timeZone)] + (team ? entry.team.map { ["team \(PromptScreen.visible($0))"] } ?? [] : [])).joined(separator: " \(style.dot) ")
    }

    static func apps(_ entry: DeviceAllowance) -> String {
        entry.apps.isEmpty ? "any app" : entry.allowsWholeDevice ? "any app and all logs" : entry.apps.map { PromptScreen.label($0) }.joined(separator: ", ")
    }

    static func until(_ entry: DeviceAllowance, now: Date, timeZone: TimeZone) -> String {
        entry.expires == nil ? "until removed" : AllowScreen.until(entry.expires, now: now, timeZone: timeZone)
    }

    public static func name(_ entry: DeviceAllowance) -> String {
        PromptScreen.label(entry.name.hasPrefix("Apple ") ? String(entry.name.dropFirst(6)) : entry.name)
    }

    /// The devices agents may control now; expired and refused entries are left out.
    public static func allowed(_ policy: PhysicalDevicePolicy, now: Date) -> [DeviceAllowance] {
        policy.list.entries.filter { policy.decision(platform: $0.platform, key: $0.key, now: now) == .allowed($0) }
    }

    /// The one warning the screen carries, or nil.
    public static func warning(_ policy: PhysicalDevicePolicy, now: Date) -> String? {
        if policy.managed.unreadable || policy.managed.allowPhysicalDevices == false { return managedBlocksAll }
        if policy.listProblem != nil { return listUnreadable }
        if !policy.sealIntact, !policy.list.entries.isEmpty { return listChanged }
        let blocked = policy.list.entries.contains { entry in
            if case .refused(let refusal) = policy.decision(platform: entry.platform, key: entry.key, now: now) { return refusal.isManaged }
            return false
        }
        return blocked ? managedBlocksSome : nil
    }

    /// A person's page; `agent` is what an agent reads on stdout instead, as it always did.
    public static func page(_ policy: PhysicalDevicePolicy, now: Date, timeZone: TimeZone, agent: String = "") -> Page {
        var notices: [Notice] = []
        if let warning = warning(policy, now: now) {
            let allowAgain = [listChanged, listUnreadable].contains(warning)
            notices.append(.warning(warning, try: allowAgain ? allowCommand : nil))
        }
        let entries = allowed(policy, now: now)
        guard !entries.isEmpty else {
            let person: [Block] = [.header(Header(.lock, title, ["none allowed"])), .prose(nothingAllowed)]
            return Page([.person(person), .agent(agent)], notices: notices + (notices.contains { $0.command == allowCommand } ? [] : [.next(allowCommand)]))
        }
        let rows = entries.map { entry in
            Table.Row([
                Table.Cell(name(entry)),
                Table.Cell(apps(entry)),
                Table.Cell(until(entry, now: now, timeZone: timeZone)),
                entry.team.map { Table.Cell("team \(PromptScreen.visible($0))") },
            ], status: .on)
        }
        let table = Table(columns: [
            Table.Column(agent: "NAME", person: 0, fit: .cut(min: 12)),
            Table.Column(agent: "APPS", person: 1, fit: .cut(min: 12), tone: .dim),
            Table.Column(agent: "UNTIL", person: 2, fit: .whole, tone: .dim),
            Table.Column(agent: "TEAM", person: 3, fit: .optional(priority: 1), tone: .dim),
        ], rows: rows)
        let commands = Block.commands(title: nil, [
            Shortcut(allowCommand, "allow another"),
            Shortcut(removeCommand(entries.count == 1 ? entries[0].key : "<id>"), "withdraw \(entries.count == 1 ? "it" : "one")"),
        ])
        let person: [Block] = [.header(Header(.lock, title, ["\(entries.count) allowed"])), .table(table), commands]
        return Page([.person(person), .agent(agent)], notices: notices)
    }
}
