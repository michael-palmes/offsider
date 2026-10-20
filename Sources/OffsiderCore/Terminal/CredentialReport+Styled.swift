import Foundation

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
