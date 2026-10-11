import Foundation

/// The words and layout of the prompts Offsider shows a person at a terminal. Nothing here prints a secret.
public enum PromptScreen {
    public static let keychainLine = "🔒 Stays in your Mac's Keychain, never shown"
    public static let cancelledNothingSaved = "👋 No worries, nothing saved."
    public static let cancelledNothingLinked = "👋 No worries, nothing linked."
    public static let menuHint = "↑↓ move · ⏎ choose · esc cancel"
    public static let mismatch = "❌ Those didn't match. Try again."
    public static let untypeable = "❗ Use characters a keyboard can type (no accents or emoji)."

    /// A bold title, then dim reassurance lines under it.
    public static func header(_ title: String, _ notes: [String], style: TerminalStyle) -> [String] {
        [style.bold(title)] + notes.map { "   " + style.dim($0) } + [""]
    }

    /// Prompt labels padded to one width, so the answers line up.
    public static func labels(_ labels: [String]) -> [String] {
        let widest = labels.map(TerminalText.width).max() ?? 0
        return labels.map { $0 + String(repeating: " ", count: widest - TerminalText.width($0) + 2) }
    }

    /// The menu with `selected` marked: a title, one row per option and the key hint.
    public static func menu(_ title: String, options: [String], selected: Int, style: TerminalStyle) -> String {
        var lines = [style.bold(title)]
        for (index, option) in options.enumerated() {
            lines.append(index == selected ? "  " + style.green("❯ " + option) : "    " + option)
        }
        lines.append("  " + style.dim(menuHint))
        return lines.joined(separator: "\n")
    }

    public static func chosen(_ option: String, style: TerminalStyle) -> String {
        "  " + style.green("▸ " + option)
    }

    /// One bullet per character typed, never the characters.
    public static func dots(_ count: Int) -> String {
        String(repeating: "•", count: count)
    }

    /// Typed text as drawn: a control character shows as `?`, never as itself.
    public static func visible(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.map { $0.value < 0x20 || $0.value == 0x7F ? "?" : $0 }))
    }

    public static func nextStep(_ label: String, command: String, style: TerminalStyle) -> String {
        "   " + style.dim("▶ \(label): ") + style.cyan(command)
    }
}

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
    public static let addAnother = "➕ Add another login"

    /// Every `credential set` question, so the answers line up across the whole block.
    public static let promptLabels = [nameLabel, usernameLabel, passwordLabel, againLabel, aboutLabel, tagsLabel]

    /// `label` padded to the widest of `promptLabels`.
    public static func padded(_ label: String) -> String {
        Dictionary(uniqueKeysWithValues: zip(promptLabels, PromptScreen.labels(promptLabels)))[label] ?? label
    }

    public static func header(app: String, key: String?, style: TerminalStyle) -> [String] {
        let name = key.map { " · " + LoginCredential.displayKey($0) } ?? ""
        return PromptScreen.header("🔐 Save a test login · \(app)\(name)", [PromptScreen.keychainLine, "🧪 Use a test account, not your own"], style: style)
    }

    public static func menuTitle(entries: [LoginCredentialSummary]) -> String {
        entries.count == 1 ? "📋 This app already has a login" : "📋 This app already has \(entries.count) logins"
    }

    /// One row per saved login to update, then a row to add another. The order matches `LoginDirectory.setChoice(at:entries:)`.
    public static func menuOptions(entries: [LoginCredentialSummary]) -> [String] {
        entries.map { entry in
            let mark = entry.isDefault && entry.key != LoginCredential.defaultAccountKey ? " (default)" : ""
            return "📝 Update \(LoginCredential.displayKey(entry.key))\(mark) · \(entry.username)"
        } + [addAnother]
    }

    public static func replaceTitle(_ entry: LoginCredentialSummary) -> String {
        "📋 \(LoginCredential.displayKey(entry.key)) is already saved · \(entry.username)"
    }

    public static let replaceOptions = ["📝 Replace it", "✋ Keep it"]

    public static let joinTitle = "🔗 Share logins with which app?"

    public static func joinOptions(groups: [LoginAppGroup]) -> [String] {
        groups.map { group in
            group.members.isEmpty ? "📱 \(group.canonical)" : "📱 \(group.canonical) (also \(group.members.joined(separator: ", ")))"
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

extension CredentialReport {
    /// The report for a person at a terminal. `device` names the device in a next step, or is empty when `OFFSIDER_DEVICE` does.
    public func styledText(style: TerminalStyle, device: String) -> String {
        let shown = key.map(LoginCredential.displayKey) ?? "default"
        let named = shown == "default" ? "default login" : "\(shown) login"
        let shared = also.isEmpty ? [] : ["🔗 also \(also.joined(separator: ", "))"]
        let deviceSuffix = device.isEmpty ? "" : " \(device)"
        switch action {
        case "join":
            guard let linked else { return "🤷 \(app) was not linked" }
            if saved {
                return [style.green(style.bold("🔗 Linked \(app) to \(linked)")), "   " + style.dim("Both share the same saved logins.")].joined(separator: "\n")
            }
            return style.bold("🔗 \(app) already shares logins with \(linked)")
        case "set":
            var details = ["👤 \(username ?? "")", "🔑 hidden", "🔒 Keychain"]
            if isDefault, key != nil, key != LoginCredential.defaultAccountKey { details.append("⭐ default") }
            let nameArgument = key == nil || key == LoginCredential.defaultAccountKey ? "" : " \(shown)"
            return ([
                style.green(style.bold("✅ Saved the \(named) for \(app)")),
                "   " + style.dim((details + shared).joined(separator: "  ")),
            ] + Self.styledDetails(context ?? .empty, signIns: [], indent: "   ", style: style) + [
                PromptScreen.nextStep("Next", command: "offsider login\(nameArgument)\(deviceSuffix)", style: style),
            ]).joined(separator: "\n")
        case "remove":
            return removed ? style.bold("🧹 Removed the \(named) for \(app)") : style.bold("🤷 No \(named) to remove for \(app)")
        case "describe":
            let head = changed == true ? style.green(style.bold("📝 Updated the \(named) for \(app)")) : style.bold("👌 Nothing to change for the \(named) of \(app)")
            return ([head] + Self.styledDetails(context ?? .empty, signIns: [], indent: "   ", style: style)).joined(separator: "\n")
        default:
            if key == nil {
                guard !listed.isEmpty else {
                    return [style.bold("🔐 No logins saved for \(app)"), PromptScreen.nextStep("Add one", command: "offsider credential set --app \(app)", style: style)].joined(separator: "\n")
                }
                let count = listed.count == 1 ? "1 login" : "\(listed.count) logins"
                let widest = listed.map(\.name.count).max() ?? 0
                let rows = listed.flatMap { entry in
                    let mark = entry.isDefault && entry.key != LoginCredential.defaultAccountKey ? "  " + style.yellow("⭐ default") : ""
                    let row = "   👤 " + style.bold(entry.name.padding(toLength: widest, withPad: " ", startingAt: 0)) + mark
                    return [row] + Self.styledDetails(entry.context, signIns: signIns[entry.key] ?? [], indent: "      ", style: style)
                }
                return ([style.bold("🔐 \(app) · \(count)")] + rows + (shared + here).map { "   " + style.dim($0) }).joined(separator: "\n")
            }
            guard saved else {
                let nameArgument = key == LoginCredential.defaultAccountKey ? "" : " \(shown)"
                return [style.bold("🔐 No \(named) saved for \(app)"), PromptScreen.nextStep("Add it", command: "offsider credential set\(nameArgument) --app \(app)", style: style)].joined(separator: "\n")
            }
            let details = (username.map { ["👤 \($0)"] } ?? []) + (isDefault && key != LoginCredential.defaultAccountKey ? ["⭐ default"] : []) + shared
            let rows = Self.styledDetails(context ?? .empty, signIns: key.flatMap { signIns[$0] } ?? [], indent: "   ", style: style)
            let head = filter.isEmpty
                ? style.green(style.bold("✅ The \(named) is saved for \(app)"))
                : style.green(style.bold("🎯 The \(named) for \(app) matches --where \(filter.map(\.rawValue).joined(separator: " "))"))
            let detailLine = details.isEmpty ? [] : ["   " + style.dim(details.joined(separator: "  "))]
            return ([head] + detailLine + rows + here.map { "   " + style.dim($0) }).joined(separator: "\n")
        }
    }

    private var here: [String] {
        signedInHere.map { ["📱 signed in here: \(LoginCredential.displayKey($0))"] } ?? []
    }

    /// Dim rows for tags, notes, the stamp and each sign-in. Every emoji draws as one without a variation selector.
    static func styledDetails(_ context: LoginContext, signIns: [LoginSignIn], indent: String, style: TerminalStyle) -> [String] {
        var rows: [String] = []
        if !context.tags.isEmpty { rows.append("🔖 " + context.tags.map(\.rawValue).joined(separator: " ")) }
        let marks: [LoginNote: String] = [.about: "💬", .avoid: "🚫", .state: "📊"]
        for note in LoginNote.allCases {
            if let text = context[note], let mark = marks[note] { rows.append("\(mark) \(text)") }
        }
        if let updated = context.updated { rows.append("🕒 updated \(LoginContext.timestamp(updated))") }
        rows += signIns.map { "📱 signed in on " + signInText($0) }
        return rows.map { indent + style.dim($0) }
    }
}

/// What `unlock-code` shows on a terminal.
public enum UnlockCodeScreen {
    public static let codeLabel = "🔑 PIN or password"
    public static let againLabel = "🔁 Once more"

    public static func header(name: String, style: TerminalStyle) -> [String] {
        PromptScreen.header("🔐 Save the unlock code · \(name)", [PromptScreen.keychainLine, "🧪 Use on test devices only"], style: style)
    }

    public static func codeProblem(_ code: String) -> String? {
        UnlockCode(code) == nil ? "❗ Use \(UnlockCode.lengths.lowerBound) to \(UnlockCode.lengths.upperBound) keyboard characters (a PIN is 4 to 16 digits)." : nil
    }

    public static func saved(name: String, device: String, style: TerminalStyle) -> String {
        [style.green(style.bold("✅ Saved the unlock code for \(name)")), PromptScreen.nextStep("Next", command: "offsider wake --unlock --device \(device)", style: style)].joined(separator: "\n")
    }

    public static func status(name: String, device: String, saved: Bool, lastAttemptFailed: Bool, style: TerminalStyle) -> String {
        guard saved else {
            return [style.bold("🔐 No unlock code saved for \(name)"), PromptScreen.nextStep("Add one", command: "offsider unlock-code set --device \(device)", style: style)].joined(separator: "\n")
        }
        guard lastAttemptFailed else { return style.green(style.bold("✅ Unlock code saved for \(name)")) }
        return [
            style.yellow(style.bold("❗ Unlock code saved for \(name), but it failed last time")),
            "   " + style.dim("Offsider won't type it until you unlock by hand or save it again."),
            PromptScreen.nextStep("Save it again", command: "offsider unlock-code set --device \(device)", style: style),
        ].joined(separator: "\n")
    }

    public static func removed(name: String, removed: Bool, style: TerminalStyle) -> String {
        style.bold(removed ? "🧹 Removed the unlock code for \(name)" : "🤷 No unlock code saved for \(name)")
    }
}
