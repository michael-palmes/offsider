import Foundation

/// What `devices status` shows a person: a header that counts the devices agents may control now, a row for each,
/// a warning when the managed policy or a broken list refuses devices, and the commands to change it.
public enum AccessStatusScreen {
    public static let title = "Phones and tablets agents may control"
    public static let nothingAllowed = "Nothing allowed yet."
    public static let managedBlocksAll = "Managed policy blocks every device."
    public static let managedBlocksSome = "Managed policy blocks some devices."
    public static let listChanged = "List changed outside Offsider. Allow again."
    public static let listUnreadable = "List unreadable. Allow again."
    public static let allowCommand = "offsider devices add"

    /// With one device, the command that withdraws it; with several, the bare command whose menu picks one.
    public static func removeCommand(_ key: String?) -> String { "offsider devices remove" + (key.map { " --device \(PromptScreen.visible($0))" } ?? "") }

    /// `any app · until 22:14`, `com.example.app · until removed`, with `· team ABCDE12345` when `team` is on and the entry has one.
    public static func detail(_ entry: DeviceAllowance, now: Date, timeZone: TimeZone, team: Bool, style: TerminalStyle) -> String {
        let metro = entry.metroPorts.isEmpty ? [] : [AllowScreen.metro(entry.metroPorts)]
        return ([apps(entry)] + metro + [until(entry, now: now, timeZone: timeZone)] + (team ? entry.team.map { ["team \(PromptScreen.visible($0))"] } ?? [] : [])).joined(separator: " \(style.dot) ")
    }

    static func apps(_ entry: DeviceAllowance) -> String {
        if entry.testDevice { return "test device" }
        return entry.apps.isEmpty ? "any app" : entry.allowsWholeDevice ? "any app and all logs" : entry.apps.map { PromptScreen.label($0) }.joined(separator: ", ")
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

    /// `Test Pixel needs a newer Offsider.`, or how many do.
    public static func newerNeeded(_ policy: PhysicalDevicePolicy) -> String? {
        guard let first = policy.list.newer.first else { return nil }
        return policy.list.newer.count == 1 ? "\(PromptScreen.label(first.name)) needs a newer Offsider." : "\(policy.list.newer.count) devices need a newer Offsider."
    }

    /// A test device is marked, and says so when managed policy has turned it into a plain Any app allowance.
    static func appsCell(_ entry: DeviceAllowance, policy: PhysicalDevicePolicy, style: TerminalStyle) -> Table.Cell {
        guard entry.testDevice else { return Table.Cell(apps(entry)) }
        let text = policy.drivesWhole(entry) ? AllowScreen.wholeDevice : "any app, \(policy.managed.testDeviceRefusal ?? "")"
        return Table.Cell(text, person: style.mark(.testDevice) + " " + text)
    }

    /// The one warning the screen carries, or nil.
    public static func warning(_ policy: PhysicalDevicePolicy, now: Date) -> String? {
        if policy.managed.unreadable || policy.managed.allowPhysicalDevices == false { return managedBlocksAll }
        if policy.listProblem != nil { return listUnreadable }
        if !policy.sealIntact, !policy.list.isEmpty { return listChanged }
        let blocked = policy.list.entries.contains { entry in
            if case .refused(let refusal) = policy.decision(platform: entry.platform, key: entry.key, now: now) { return refusal.isManaged }
            return false
        }
        return blocked ? managedBlocksSome : newerNeeded(policy)
    }

    /// A person's page; `agent` is what an agent reads on stdout instead, as it always did.
    public static func page(_ policy: PhysicalDevicePolicy, now: Date, timeZone: TimeZone, agent: String = "", style: TerminalStyle = .detect(isTerminal: false)) -> Page {
        var notices: [Notice] = []
        if let warning = warning(policy, now: now) {
            let allowAgain = [listChanged, listUnreadable].contains(warning)
            notices.append(.warning(warning, try: allowAgain ? allowCommand : warning == newerNeeded(policy) ? NewerDeviceEntry.updateCommand : nil))
        }
        let entries = allowed(policy, now: now)
        guard !entries.isEmpty else {
            let person: [Block] = [.header(Header(.lock, title, ["none allowed"])), .prose(nothingAllowed)]
            return Page([.person(person), .agent(agent)], notices: notices + (notices.contains { $0.command == allowCommand } ? [] : [.next(allowCommand)]))
        }
        let rows = entries.map { entry in
            Table.Row([
                Table.Cell(name(entry)),
                appsCell(entry, policy: policy, style: style),
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
            Shortcut(allowCommand, "add another"),
            Shortcut(removeCommand(entries.count == 1 ? entries[0].key : nil), "withdraw \(entries.count == 1 ? "it" : "one")"),
        ])
        let person: [Block] = [.header(Header(.lock, title, ["\(entries.count) allowed"])), .table(table), commands]
        return Page([.person(person), .agent(agent)], notices: notices)
    }
}
