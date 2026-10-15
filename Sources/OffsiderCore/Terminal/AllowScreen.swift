import Foundation

/// What `device-access allow` shows, drawn with `TerminalUI`: a banner, one short question per step that collapses to a
/// receipt line, a bold summary before Touch ID, and a closing block that names the full ID only in its commands.
public enum AllowScreen {
    public static let title = "Allow agents to control which phone or tablet"
    public static let deviceQuestion = "Which phone or tablet?"
    public static let teamQuestion = "Which team?"
    public static let appQuestion = "Which app?"
    public static let expiryQuestion = "For how long?"
    public static let anotherQuestion = "Allow another?"
    public static let noDevice = "Nothing over USB. Plug in, unlock, trust this Mac."
    public static let wifiOnly = "Wi-Fi only, plug in a cable"
    public static let allAllowed = "All connected devices are allowed."
    public static let anyApp = "Any app"
    public static let typeApp = "Type an app ID"
    public static let typeTeam = "Type a team ID"
    public static let noTeam = "No team in your Keychain. Type one, or Return to skip."
    public static let done = "Done"
    public static let confirm = "Touch ID or your password to confirm."
    public static let cancelled = PromptScreen.cancelledNothingSaved

    public static func header(width: Int, style: TerminalStyle) -> [String] {
        TerminalUI.banner(title, mark: .lock, width: width, style: style) + [""]
    }

    /// The name a person knows the device by: the marketing name without "Apple", or the model the phone reports.
    public static func name(_ row: DeviceSummary) -> String {
        PromptScreen.label(row.name.hasPrefix("Apple ") ? String(row.name.dropFirst(6)) : row.name)
    }

    /// 📱 for an iPhone, 📲 for an iPad, 🤖 for an Android phone.
    public static func mark(_ row: DeviceSummary) -> TerminalStyle.Mark {
        switch row.platform {
        case .android: return .android
        case .ios: return [row.deviceType, row.name].contains { $0?.contains("iPad") == true } ? .iPad : .iPhone
        }
    }

    /// A connected device as a menu row: its mark, name and the ID's last four characters. A Wi-Fi device is drawn but cannot be chosen.
    public static func deviceRow(_ row: DeviceSummary, key: String, style: TerminalStyle) -> MenuRow {
        guard row.connection == "usb" else { return MenuRow(mark(row), [name(row), wifiOnly], enabled: false) }
        return MenuRow(mark(row), [name(row), style.ellipsis + PromptScreen.visible(String(key.suffix(4)))])
    }

    /// A connected device agents may already control: dim, never chosen, with `allowed · any app · until 22:14` for its detail.
    public static func allowedRow(_ row: DeviceSummary, detail: String, style: TerminalStyle) -> MenuRow {
        MenuRow(mark(row), [name(row), "allowed \(style.dot) " + detail], enabled: false)
    }

    /// `12 hours`, `7 days`, `45 minutes`, or `until removed`.
    public static func duration(_ seconds: TimeInterval?) -> String {
        guard let seconds else { return "until removed" }
        func count(_ value: Int, _ unit: String) -> String { "\(value) \(unit)\(value == 1 ? "" : "s")" }
        if seconds >= 86_400, seconds.truncatingRemainder(dividingBy: 86_400) == 0 { return count(Int(seconds / 86_400), "day") }
        if seconds >= 3_600, seconds.truncatingRemainder(dividingBy: 3_600) == 0 { return count(Int(seconds / 3_600), "hour") }
        return count(Int(seconds / 60), "minute")
    }

    public static func apps(_ apps: [String]) -> String {
        apps.isEmpty ? "any app" : apps.map { PromptScreen.label($0) }.joined(separator: ", ") + " only"
    }

    /// The bold line above the Touch ID request: what is about to be allowed. `team` is the name shown, or `team <id>` when only the ID is known.
    public static func summary(_ row: DeviceSummary, apps: [String], lifetime: TimeInterval?, team: String?, width: Int, style: TerminalStyle) -> [String] {
        TerminalUI.summary(mark(row), [name(row), Self.apps(apps), duration(lifetime)] + (team.map { [$0] } ?? []), width: width, style: style)
    }

    /// `until 22:14` today, `until 21 Oct 22:14` on a later day, or `until you remove it`.
    public static func until(_ expires: Date?, now: Date, timeZone: TimeZone) -> String {
        guard let expires else { return "until you remove it" }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_AU_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = calendar.isDate(expires, inSameDayAs: now) ? "HH:mm" : "d MMM HH:mm"
        return "until " + formatter.string(from: expires)
    }

    /// The closing block for one device: the only place the full ID shows, since the commands need it.
    public static func allowed(name: String, key: String, until: String, apps: [String], width: Int, style: TerminalStyle) -> [String] {
        let key = PromptScreen.visible(key)
        return TerminalUI.closing("Allowed \(name) \(until), \(Self.apps(apps)).", commands: [
            ("Withdraw", "offsider device-access remove --device \(key)"),
            ("Next", "offsider doctor --device \(key)"),
        ], width: width, style: style)
    }
}
