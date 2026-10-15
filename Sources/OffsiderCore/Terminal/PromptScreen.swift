import Foundation

/// The words and layout of the prompts Offsider shows a person at a terminal. Nothing here prints a secret.
public enum PromptScreen {
    public static let cancelledNothingSaved = "👋 Cancelled, nothing saved."
    public static let cancelledNothingLinked = "👋 Cancelled, nothing linked."
    public static let mismatch = "❌ Those didn't match. Try again."
    public static let untypeable = "❗ Use characters a keyboard can type (no accents or emoji)."


    /// Prompt labels padded to one width, so the answers line up.
    public static func labels(_ labels: [String]) -> [String] {
        let widest = labels.map(TerminalText.width).max() ?? 0
        return labels.map { $0 + String(repeating: " ", count: widest - TerminalText.width($0) + 2) }
    }

    /// The widest a block of prose runs: the terminal, at most 72 columns, never under 20.
    public static func width(columns: Int?) -> Int {
        min(max(columns ?? 72, 20), 72)
    }

    /// `text` broken between words to fit `width`; continuation lines start with `indent`. Runs of spaces inside a line stay,
    /// so columns keep their alignment; a word wider than a line stays whole.
    public static func wrap(_ text: String, width: Int, indent: String = "") -> [String] {
        var lines: [String] = []
        var line = ""
        var gap = ""
        var word = ""
        func place() {
            guard !word.isEmpty else { return }
            if line.isEmpty || TerminalText.width(line + gap + word) <= width {
                line += gap + word
            } else {
                lines.append(line)
                line = indent + word
            }
            gap = ""
            word = ""
        }
        for character in text {
            if character == " " {
                if !word.isEmpty { place() }
                gap.append(character)
            } else {
                word.append(character)
            }
        }
        place()
        return lines + [line]
    }

    /// `parts` joined by `separator`, breaking lines only between parts, so a phrase such as `team ABCDE12345` stays whole.
    public static func pack(_ parts: [String], separator: String, width: Int, indent: String = "") -> [String] {
        var lines: [String] = []
        var line = ""
        for part in parts {
            if line.isEmpty {
                line = (lines.isEmpty ? "" : indent) + part
            } else if TerminalText.width(line + separator + part) <= width {
                line += separator + part
            } else {
                lines.append(line + String(separator.reversed().drop { $0 == " " }.reversed()))
                line = indent + part
            }
        }
        return lines + [line]
    }

    /// One bullet per character typed, never the characters.
    public static func dots(_ count: Int) -> String {
        String(repeating: "•", count: count)
    }

    /// Typed text as drawn: a control, bidi, zero-width or other invisible character shows as `?`, never as itself.
    public static func visible(_ text: String) -> String {
        var previous: Unicode.Scalar?
        return String(String.UnicodeScalarView(text.unicodeScalars.map { scalar in
            defer { previous = scalar }
            return TerminalText.isHazard(scalar, after: previous) ? "?" : scalar
        }))
    }

    /// A name or ID from a device or the Keychain, for a menu row, receipt or summary: `visible`, and cut so it stays on one row.
    public static func label(_ text: String, cap: Int = 60) -> String {
        visible(TerminalText.capped(text, cap: cap))
    }

    /// A command to run next under a report's headline: the label dim, the command cyan and never wrapped.
    public static func nextStep(_ label: String, command: String, style: TerminalStyle) -> String {
        "   " + style.dim(label) + "  " + style.cyan(command)
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
            if key == LoginCredential.defaultAccountKey, !removed { return style.bold("🤷 No login named default was saved for \(app)") }
            return removed ? style.bold("🧹 Removed the \(named) for \(app)") : style.bold("🤷 No \(named) to remove for \(app)")
        case "signed-out":
            let place = "\(app) on \(self.device ?? "")"
            guard cleared == true, key != nil else { return style.bold("🤷 No sign-in recorded for \(place)") }
            return [
                style.bold("🧹 Cleared the sign-in of the \(named) for \(place)"),
                PromptScreen.nextStep("Next", command: "offsider login\(deviceSuffix)", style: style),
            ].joined(separator: "\n")
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
                if key == LoginCredential.defaultAccountKey {
                    return [style.bold("🔐 No login named default saved for \(app)"), PromptScreen.nextStep("See the saved logins", command: "offsider credential status --app \(app)", style: style)].joined(separator: "\n")
                }
                return [style.bold("🔐 No \(named) saved for \(app)"), PromptScreen.nextStep("Add it", command: "offsider credential set \(shown) --app \(app)", style: style)].joined(separator: "\n")
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
        if let updated = context.updated { rows.append("🕒 updated \(ProcessStamp.timestamp(updated))") }
        rows += signIns.map { "📱 signed in on " + signInText($0) }
        return rows.map { indent + style.dim($0) }
    }
}

/// What `unlock-code` shows on a terminal.
public enum UnlockCodeScreen {
    public static let codeLabel = "🔑 PIN or password"
    public static let againLabel = "🔁 Once more"

    public static func header(name: String, width: Int, style: TerminalStyle) -> [String] {
        TerminalUI.banner("Save the unlock code for \(name)", mark: .lock, width: width, style: style) + [""]
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

/// What `init` prints on a terminal: each `Installed Offsider skill -> Client: path` line as a bold `✅` line with the path dim
/// under it, and `Next: <command>` as a next step. Piped output keeps the plain lines.
public enum InitScreen {
    public static let agentsQuestion = "Which agents?"
    public static let cancelled = "👋 Cancelled, nothing installed."

    /// `path` with the home folder written as `~`.
    public static func shortPath(_ path: String, home: String) -> String {
        path == home || path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    public static func styled(_ lines: [String], style: TerminalStyle) -> [String] {
        lines.flatMap { line -> [String] in
            if line.hasPrefix("Next: ") { return [PromptScreen.nextStep("Next", command: String(line.dropFirst(6)), style: style)] }
            guard let arrow = line.range(of: " -> "), let colon = line.range(of: ": ", range: arrow.upperBound..<line.endIndex) else { return [line] }
            let head = "\(line[..<arrow.lowerBound]) for \(line[arrow.upperBound..<colon.lowerBound])"
            return [style.mark(.done) + " " + style.bold(head), "   " + style.dim(String(line[colon.upperBound...]))]
        }
    }
}
