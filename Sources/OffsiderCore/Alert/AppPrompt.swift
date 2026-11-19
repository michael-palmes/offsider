import Foundation

/// A permission or consent prompt the system shows for one app, as `alert` reads it.
public struct AppPrompt: Equatable, Sendable {
    public struct Button: Equatable, Sendable {
        public enum Role: String, Sendable {
            /// The grant `accept` picks: the narrowest one that lasts.
            case accept
            /// The button `deny` picks.
            case deny
            /// Any other answer, which only `choose` picks.
            case other
        }

        public var label: String
        public var role: Role
        public var frame: UIFrame

        public init(label: String, role: Role, frame: UIFrame) {
            self.label = label
            self.role = role
            self.frame = frame
        }
    }

    /// The app the prompt was raised by, or over.
    public var app: String
    public var title: String
    /// An iOS alert's second line.
    public var message: String?
    public var buttons: [Button]
    /// The prompt's box on screen; a capture paints everything outside it.
    public var frame: UIFrame
    /// The package or process that draws it.
    public var source: String?
    /// Changes when another window takes the prompt's place.
    public var token: String

    public init(app: String, title: String, message: String? = nil, buttons: [Button], frame: UIFrame, source: String? = nil, token: String = "") {
        self.app = app
        self.title = title
        self.message = message
        self.buttons = buttons
        self.frame = frame
        self.source = source
        self.token = token
    }

    /// What `alert` was asked to do with the prompt.
    public enum Choice: Equatable, Sendable {
        case accept
        case deny
        case label(String)

        public var word: String {
            switch self {
            case .accept: return "accept"
            case .deny: return "deny"
            case .label: return "choose"
            }
        }
    }

    public enum ChoiceFailure: Error, Equatable, Sendable {
        /// The prompt has no button Offsider can tell grants, or declines.
        case noButton(Choice)
        case unknownLabel(String)
        case ambiguousLabel(String)
    }

    /// The one button `choice` names; a label matches a button's text exactly, quote style and spacing aside.
    public func button(for choice: Choice) throws -> Button {
        switch choice {
        case .accept, .deny:
            let role: Button.Role = choice == .accept ? .accept : .deny
            let found = buttons.filter { $0.role == role }
            guard found.count == 1 else { throw ChoiceFailure.noButton(choice) }
            return found[0]
        case .label(let text):
            let wanted = SelectorText.folded(text)
            let found = buttons.filter { SelectorText.folded($0.label) == wanted }
            guard let first = found.first else { throw ChoiceFailure.unknownLabel(text) }
            guard found.count == 1 else { throw ChoiceFailure.ambiguousLabel(text) }
            return first
        }
    }

    /// `{"title","message","source","buttons":[{"label","role","frame"}]}`.
    var json: OrderedJSON {
        .object([
            ("title", .string(title)),
            ("message", .optional(message, OrderedJSON.string)),
            ("source", .optional(source, OrderedJSON.string)),
            ("buttons", .array(buttons.map { button in
                .object([
                    ("label", .string(button.label)),
                    ("role", .string(button.role.rawValue)),
                    ("frame", button.frame.jsonValue),
                ])
            })),
        ])
    }

    /// `"Allow Example to take pictures?" for com.example.app`, then one button per line with its role.
    public var textLines: [String] {
        var lines = ["Prompt for \(app): \(TerminalText.quoted(SelectorText.truncated(title, limit: 200)))"]
        if let message { lines.append("  \(TerminalText.quoted(SelectorText.truncated(message, limit: 300)))") }
        lines += buttons.map { button in
            "  button \(TerminalText.quoted(SelectorText.truncated(button.label, limit: 80)))" + (button.role == .other ? "" : " (\(button.role.rawValue))")
        }
        return lines
    }
}

/// Why `alert` found no prompt it may read or answer for the app it was given.
public enum AppPromptRefusal: Error, Equatable, Sendable {
    /// Nothing the system drew is in front; `front` names the app that is, when known.
    case notShown(front: String?)
    /// A permission prompt is in front, but another app raised it, or Offsider cannot tie it to this one.
    case otherApp(requester: String?, why: String)
    /// A system window that is not a permission or consent prompt, such as a crash dialog or a save-password sheet.
    case notPermission(what: String)
    /// A permission prompt whose layout Offsider does not know, so it names no button.
    case unreadable(why: String)
}

/// What `alert` read and did.
public struct AlertReport: Equatable, Sendable {
    public var prompt: AppPrompt
    /// `show`, `accept`, `deny` or `choose`.
    public var action: String
    public var chosen: AppPrompt.Button?
    /// The prompt that took its place, as an app asking for several permissions shows them in turn.
    public var next: AppPrompt?

    public init(prompt: AppPrompt, action: String = "show", chosen: AppPrompt.Button? = nil, next: AppPrompt? = nil) {
        self.prompt = prompt
        self.action = action
        self.chosen = chosen
        self.next = next
    }

    public var textLines: [String] {
        guard let chosen else { return prompt.textLines }
        var lines = ["Answered \(TerminalText.quoted(SelectorText.truncated(prompt.title, limit: 200))) for \(prompt.app) with \(TerminalText.quoted(SelectorText.truncated(chosen.label, limit: 80))) (\(action))"]
        if let next {
            lines.append("Another prompt followed:")
            lines += next.textLines
        }
        return lines
    }

    /// `{"version":1,"device","platform","app","action","prompt":{…},"button","next","untrusted":[…]}`.
    public func jsonLine(device: DeviceID) -> String {
        var untrusted = ["prompt.title", "prompt.message", "prompt.buttons[].label"]
        if chosen != nil { untrusted.append("button") }
        if next != nil { untrusted += ["next.title", "next.message", "next.buttons[].label"] }
        return OrderedJSON.object([
            ("version", .integer(1)),
            ("device", .string(device.rawValue)),
            ("platform", .string(device.platform.rawValue)),
            ("app", .string(prompt.app)),
            ("action", .string(action)),
            ("prompt", prompt.json),
            ("button", .optional(chosen?.label, OrderedJSON.string)),
            ("next", next?.json ?? .null),
            ("untrusted", .array(untrusted.map(OrderedJSON.string))),
        ]).rendered(compact: true)
    }
}
