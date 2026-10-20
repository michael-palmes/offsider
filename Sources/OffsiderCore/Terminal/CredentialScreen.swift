import Foundation

/// What `credential` shows on a terminal: the set prompts, the menus and a short coloured report.
public enum CredentialScreen {
    public static let usernameLabel = "👤 Email or username"
    public static let passwordLabel = "🔑 Password"
    public static let againLabel = "🔁 Once more"
    public static let nameLabel = "✨ Name it"
    public static let namePlaceholder = "like qa"
    public static let aboutLabel = "💬 What's it for"
    public static let aboutPlaceholder = "optional, like Admin on staging"
    public static let tagsLabel = "🔖 Tags"
    public static let tagsPlaceholder = "optional, like role=admin env=staging"
    public static let addAnother = "➕  Add another login"

    /// Every `credential set` question, so the answers line up across the whole block.
    public static let promptLabels = [nameLabel, usernameLabel, passwordLabel, againLabel, aboutLabel, tagsLabel]

    /// `label` padded to the widest of `promptLabels`.
    public static func padded(_ label: String) -> String {
        Dictionary(uniqueKeysWithValues: zip(promptLabels, PromptScreen.labels(promptLabels)))[label] ?? label
    }

    public static func header(app: String, key: String?, width: Int, style: TerminalStyle) -> [String] {
        let title = key.map { "Save the \(LoginCredential.displayKey($0)) login for \(app)" } ?? "Save a test login for \(app)"
        return TerminalUI.banner(title, mark: .lock, width: width, style: style) + [""]
    }

    public static func menuTitle(entries: [LoginCredentialSummary]) -> String {
        "Update or add a login?"
    }

    /// One row per saved login to update, then a row to add another. The order matches `LoginDirectory.setChoice(at:entries:)`.
    public static func menuOptions(entries: [LoginCredentialSummary]) -> [String] {
        entries.map { entry in
            let mark = entry.isDefault && entry.key != LoginCredential.defaultAccountKey ? " (default)" : ""
            return "📝  Update \(LoginCredential.displayKey(entry.key))\(mark) · \(entry.username)"
        } + [addAnother]
    }

    public static func replaceTitle(_ entry: LoginCredentialSummary) -> String {
        "Replace the saved \(LoginCredential.displayKey(entry.key))?"
    }

    public static let replaceOptions = ["📝  Replace it", "✋  Keep it"]

    public static let joinTitle = "Share logins with which app?"

    public static func joinOptions(groups: [LoginAppGroup]) -> [String] {
        groups.map { group in
            group.members.isEmpty ? "📱  \(group.canonical)" : "📱  \(group.canonical) (also \(group.members.joined(separator: ", ")))"
        }
    }

    /// Why a typed username cannot be saved, or nil when it can.
    public static func usernameProblem(_ raw: String) -> String? {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { return "❗ Type an email or username." }
        if name.count > LoginCredential.usernameLengths.upperBound { return "❗ That's too long: \(LoginCredential.usernameLengths.upperBound) characters at most." }
        return TextToHIDEvents.validateText(name) ? nil : PromptScreen.untypeable
    }

    /// Why a typed password cannot be saved, or nil when it can. The message never repeats it.
    public static func passwordProblem(_ password: String) -> String? {
        if password.isEmpty { return "❗ Type a password." }
        if password.count > LoginCredential.passwordLengths.upperBound { return "❗ That's too long: \(LoginCredential.passwordLengths.upperBound) characters at most." }
        return TextToHIDEvents.validateText(password) ? nil : PromptScreen.untypeable
    }

    /// Why a typed name cannot name a new login, or nil when it can.
    public static func nameProblem(_ raw: String, taken: [String]) -> String? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return "❗ Type a short name, like qa." }
        if text.lowercased() == "default" { return "❗ default is taken. Pick another name." }
        guard let key = LoginKey(rawValue: text) else { return "❗ Use up to 32 letters, digits, dots, dashes or underscores." }
        return taken.contains(key.rawValue) ? "❗ \(key.rawValue) is already saved. Pick another name." : nil
    }

    /// Why a typed about line cannot be saved, or nil when it can. An empty answer skips it.
    public static func aboutProblem(_ raw: String) -> String? {
        switch LoginContext.noteProblem(raw) {
        case nil: return nil
        case .control: return "❗ Keep it to one line."
        case .bidi: return "❗ Leave out text direction characters."
        case .tooLong: return "❗ That's too long: \(LoginContext.noteCharacters) characters at most."
        case .email: return "❗ Leave out email addresses: anyone who runs status sees this."
        }
    }

    /// Why typed tags cannot be saved, naming the rule, or nil when they can. An empty answer skips them.
    public static func tagsProblem(_ raw: String) -> String? {
        let words = raw.split(whereSeparator: \.isWhitespace).map(String.init)
        if let bad = words.first(where: { LoginTag(rawValue: $0) == nil }) {
            if bad.lowercased().hasPrefix(LoginTag.platformKey) { return "❗ \(PromptScreen.visible(bad)) is not a tag: platform takes ios or android, like platform=ios." }
            return "❗ \(PromptScreen.visible(bad)) is not a tag: use a word or key=value, like credit or role=admin, from a-z, 0-9, '.', '_' and '-'."
        }
        return Set(words.compactMap(LoginTag.init(rawValue:))).count > LoginContext.maxTags ? "❗ \(LoginContext.maxTags) tags at most." : nil
    }

    /// The answers to the about and tags questions as an edit. Empty answers change nothing.
    public static func contextEdit(about: String, tags: String) throws -> LoginContextEdit {
        let about = about.trimmingCharacters(in: .whitespacesAndNewlines)
        return try LoginContextEdit.parse(
            about: about.isEmpty ? nil : about, avoid: nil, state: nil,
            tag: tags.split(whereSeparator: \.isWhitespace).map(String.init), untag: [], clearTags: false
        )
    }
}
