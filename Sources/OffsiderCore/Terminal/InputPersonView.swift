import Foundation

/// What the input commands show a person: a ✅ receipt for what was sent and plain key names.
/// An agent reads the lines each command always printed, or nothing for one that was silent; typed text and its length never show.
public enum InputPersonView {
    /// A person's receipt on stdout; an agent reads `agent` as it is, so a silent command stays silent.
    public static func receipt(_ headline: String, aside: String? = nil, details: [String] = [], agent: String = "") -> Page {
        Page([.person([.outcome(.done(headline, aside: aside, details: details))]), .agent(agent)])
    }

    /// `text` with its first letter capitalised, so words an agent reads mid-sentence can open a person's line.
    public static func sentence(_ text: String) -> String {
        guard let first = text.first else { return text }
        return first.uppercased() + text.dropFirst()
    }

    /// `held 1.5 s`, for a press or touch held longer than a tap.
    public static func held(_ seconds: TimeInterval) -> String {
        "held " + WaitLoop.seconds(seconds)
    }

    // MARK: Keys

    /// A key that types no character, by name: `Return`, `F5`, `Up arrow`; nil for one that types a character.
    public static func keyName(_ keycode: Int) -> String? {
        switch keycode {
        case 40: return "Return"
        case 41: return "Escape"
        case 42: return "Backspace"
        case 43: return "Tab"
        case 44: return "Space"
        case 57: return "Caps Lock"
        case 58...69: return "F\(keycode - 57)"
        case 73: return "Insert"
        case 74: return "Home key"
        case 75: return "Page Up"
        case 76: return "Forward Delete"
        case 77: return "End key"
        case 78: return "Page Down"
        case 79: return "Right arrow"
        case 80: return "Left arrow"
        case 81: return "Down arrow"
        case 82: return "Up arrow"
        default: return nil
        }
    }

    /// A modifier by the name its platform prints on the key: `Cmd` on iOS is `Meta` on Android.
    public static func modifierName(_ keycode: Int, android: Bool) -> String? {
        switch keycode {
        case 224, 228: return "Ctrl"
        case 225, 229: return "Shift"
        case 226, 230: return android ? "Alt" : "Option"
        case 227, 231: return android ? "Meta" : "Cmd"
        default: return nil
        }
    }

    /// A shortcut as a person reads it: `Cmd+A`, `Ctrl+Shift+Return`, or `key 100` for a code with no name.
    public static func combo(modifiers: [Int], key: Int, android: Bool) -> String {
        func name(_ keycode: Int) -> String {
            if let modifier = modifierName(keycode, android: android) { return modifier }
            if let named = keyName(keycode) { return named }
            let character = KeyEvent(keyCode: keycode, shift: false).stringForKeyCode
            return character.isEmpty ? "key \(keycode)" : character.uppercased()
        }
        return (modifiers + [key]).map(name).joined(separator: "+")
    }

    // MARK: Reads

    /// `turnstile`: the state for a person, with what to do when it waits on one; an agent's `Turnstile: <state>` line as it was.
    public static func turnstile(_ status: TurnstileStatus) -> Page {
        let line = status.textLine()
        let lead = "Turnstile: \(status.state.rawValue)"
        let place = status.frame != nil && line.hasPrefix(lead) ? String(line.dropFirst(lead.count)).trimmingCharacters(in: .whitespaces) : ""
        var person: [Block] = [.fields([Field("Turnstile", Table.Cell(status.state.rawValue, tag: place.isEmpty ? nil : place))])]
        switch status.state {
        case .checkbox: person.append(.prose("Tick it on the device; Offsider never does. Run this again once you have."))
        case .challenge: person.append(.prose("Solve the challenge on the device; Offsider never does. Run this again once you have."))
        case .unknown: person.append(.prose(TurnstileStatus.unknownNote))
        case .verifying, .passed, .absent: break
        }
        return Page([.person(person), .agent(line + "\n")])
    }

    /// `rn devmenu` with no item: the menu's items for a person, an app's own tagged custom; `<menu> dev menu: a, b; custom: c` for an agent.
    public static func devMenu(_ state: DevMenu.State, agent: String) -> Page {
        let name = state.menu == "expo" ? "Expo" : "React Native"
        let rows = state.items.map { Table.Row([Table.Cell($0.label, untrusted: true, tag: $0.custom ? "custom" : nil)]) }
        let table = Table(columns: [Table.Column(agent: nil, person: 0, fit: .cut(min: 16))], rows: rows)
        let count = state.items.count
        return Page([.person([.header(Header(.steps, "Dev menu", [name, count == 1 ? "1 item" : "\(count) items"])), .table(table)]), .agent(agent + "\n")])
    }

    /// `rn logbox status`: the toasts bottom first, or the open inspector, behind a header for a person; the agent's lines as they were.
    public static func logBox(_ state: LogBoxState, redacts: Bool, device: String) -> Page {
        let agent = state.text(redacts: redacts) + "\n"
        let header: Header
        var body: [Block] = []
        if let inspector = state.inspector {
            header = Header(.logs, "LogBox", ["inspector open"] + (inspector.of.map { ["log \(inspector.log ?? 1) of \($0)"] } ?? []))
            body.append(.prose("Read the log with `offsider describe-ui --device \(device)`, then close it with `offsider rn logbox dismiss --device \(device)`."))
        } else if state.toasts.isEmpty {
            header = Header(.logs, "LogBox", ["none"])
            body.append(.prose(state.emptyDialog
                ? "No logs, but an empty LogBox dialog covers the app. Reload the app to close it."
                : "No LogBox logs on screen."))
        } else {
            let logs = state.logs
            header = Header(.logs, "LogBox", [logs == 1 ? "1 log" : "\(logs) logs", state.toasts.count == 1 ? "1 toast" : "\(state.toasts.count) toasts"])
            let columns = [
                Table.Column(agent: nil, person: 0, fit: .whole, tone: .dim),
                Table.Column(agent: nil, person: 1, fit: .cut(min: 20)),
            ]
            let rows = state.toasts.map { toast in
                Table.Row([
                    Table.Cell("\(toast.index)"),
                    Table.Cell(LogBoxState.shown(toast.message, redacts: redacts), untrusted: true, tag: toast.count > 1 ? "\(toast.count) logs" : nil),
                ])
            }
            body.append(.table(Table(columns: columns, rows: rows)))
        }
        return Page([.person([.header(header)] + body), .agent(agent)])
    }

    // MARK: Sign-in

    /// `login`: who signed in and where submit was tapped, and that the server's answer is not checked; the agent's line as it was.
    public static func login(_ report: LoginReport) -> Page {
        let shown = LoginCredential.displayKey(report.key)
        let headline = report.key == LoginCredential.defaultAccountKey ? "Signed in with the default login" : "Signed in as \(shown)"
        let button = report.submitLabel.map { "tapped \(TerminalText.field($0, profile: .person))" } ?? "tapped submit"
        var details = ["\(TerminalText.field(report.app, profile: .person)): \(button)"]
        if !report.filter.isEmpty { details.append("Chosen by --where \(report.filter.map(\.rawValue).joined(separator: " "))") }
        details.append("Server answer not checked")
        if report.turnstile == .unknown { details.append(TurnstileStatus.unknownNote) }
        return receipt(headline, details: details, agent: report.textLine() + "\n")
    }
}
