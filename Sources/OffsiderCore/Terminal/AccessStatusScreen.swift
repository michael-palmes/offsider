import Foundation

/// What `device-access status` shows on a terminal, drawn with `TerminalUI`: a banner, one row per device agents may
/// control now, a yellow line when the managed policy or a broken list refuses devices, and the commands to change it.
public enum AccessStatusScreen {
    public static let title = "Phones and tablets agents may control"
    public static let nothingAllowed = "Nothing allowed yet."
    public static let managedBlocksAll = "Managed policy blocks every device."
    public static let managedBlocksSome = "Managed policy blocks some devices."
    public static let listChanged = "List changed outside Offsider. Allow again."
    public static let listUnreadable = "List unreadable. Allow again."
    public static let allowCommand = "offsider device-access allow"

    public static func removeCommand(_ key: String) -> String { "offsider device-access remove --device \(key)" }

    /// `any app · until 22:14`, `com.example.app · until removed`, with `· team ABCDE12345` when `team` is on and the entry has one.
    public static func detail(_ entry: DeviceAllowance, now: Date, timeZone: TimeZone, team: Bool, style: TerminalStyle) -> String {
        let until = entry.expires == nil ? "until removed" : AllowScreen.until(entry.expires, now: now, timeZone: timeZone)
        let apps = entry.apps.isEmpty ? "any app" : entry.apps.joined(separator: ", ")
        return ([apps, until] + (team ? entry.team.map { ["team \($0)"] } ?? [] : [])).joined(separator: " \(style.dot) ")
    }

    /// 📲 for an iPad, 📱 for an iPhone, 🤖 for an Android phone, from what the entry recorded.
    public static func mark(_ entry: DeviceAllowance) -> TerminalStyle.Mark {
        switch entry.platform {
        case .android: return .android
        case .ios: return entry.name.contains("iPad") ? .iPad : .iPhone
        }
    }

    public static func name(_ entry: DeviceAllowance) -> String {
        entry.name.hasPrefix("Apple ") ? String(entry.name.dropFirst(6)) : entry.name
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

    public static func lines(_ policy: PhysicalDevicePolicy, now: Date, timeZone: TimeZone, width: Int, style: TerminalStyle) -> [String] {
        var lines = TerminalUI.banner(title, mark: .lock, width: width, style: style) + [""]
        if let warning = warning(policy, now: now) { lines += TerminalUI.warning(warning, width: width, style: style) }
        let entries = allowed(policy, now: now)
        guard !entries.isEmpty else {
            let indent = String(repeating: " ", count: style.ascii ? style.mark(.warning).count + 1 : 3)
            return lines + TerminalUI.warning(nothingAllowed, width: width, style: style)
                + TerminalUI.commands([("Next", allowCommand)], indent: indent, style: style)
        }
        if lines.count > 4 { lines.append("") }
        lines += TerminalUI.rows(entries.map { MenuRow(mark($0), [name($0), detail($0, now: now, timeZone: timeZone, team: true, style: style)]) }, selected: nil, style: style)
        return lines + [""] + TerminalUI.commands([
            ("Allow", allowCommand),
            ("Withdraw", removeCommand(entries.count == 1 ? entries[0].key : "<id>")),
        ], indent: "  ", style: style)
    }
}
