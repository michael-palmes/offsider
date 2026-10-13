import Foundation

/// One window as Android's accessibility service lists it, in dp; iOS and the uiautomator fallback have none.
public struct UIWindowInfo: Equatable, Sendable {
    public var id: Int
    /// `application`, `inputMethod`, `system`, `accessibilityOverlay` and so on.
    public var kind: String
    public var layer: Int
    public var title: String?
    public var active: Bool
    public var focused: Bool
    public var package: String?
    public var bounds: UIFrame?

    public init(id: Int, kind: String, layer: Int, title: String?, active: Bool, focused: Bool, package: String?, bounds: UIFrame?) {
        self.id = id
        self.kind = kind
        self.layer = layer
        self.title = title
        self.active = active
        self.focused = focused
        self.package = package
        self.bounds = bounds
    }
}

/// What sits around the screen's elements: the window it is in, an open keyboard and React Native's LogBox.
public struct UITreeContext: Equatable, Sendable {
    public struct Window: Equatable, Sendable {
        public enum Kind: String, Sendable {
            case app
            /// Another application window sits beneath it, such as a dialog or a React Native `Modal`.
            case modal
            case system
        }

        public var title: String?
        public var kind: Kind
        public var package: String?
        /// An untitled modal with nothing in it, as React Native can leave its LogBox dialog on Android.
        public var empty: Bool

        public init(title: String?, kind: Kind, package: String?, empty: Bool = false) {
            self.title = title
            self.kind = kind
            self.package = package
            self.empty = empty
        }
    }

    public struct LogBox: Equatable, Sendable {
        /// Logs the toasts count.
        public var logs: Int
        public var inspector: Bool

        public init(logs: Int, inspector: Bool) {
            self.logs = logs
            self.inspector = inspector
        }
    }

    /// What a read at the screen's centre found that the tree does not list, such as a view another process draws over the app.
    public struct Presented: Equatable, Sendable {
        /// Redacted and cut to 40 characters; nil for a secure field or an element with no label.
        public var label: String?
        public var role: UIRole
        /// The executable's file name, never its path.
        public var process: String?

        public init(label: String?, role: UIRole, process: String?) {
            self.label = label
            self.role = role
            self.process = process
        }
    }

    /// A screen-sized node the tree places off screen, though a read at the screen's centre lands inside it: its frame is likely stale.
    public struct StaleFrame: Equatable, Sendable {
        public var id: String?
        public var label: String?
        public var frame: UIFrame

        public init(id: String?, label: String?, frame: UIFrame) {
            self.id = id
            self.label = label
            self.frame = frame
        }

        /// `id=sheet-host`, else the quoted label, else `a screen-sized node`.
        public var name: String {
            if let id { return "id=" + UITreeRenderer.token(SelectorText.truncated(id, limit: 40)) }
            if let label { return UITreeRenderer.quoted(SelectorText.truncated(label, limit: 40)) }
            return "a screen-sized node"
        }
    }

    /// A branch Android's helper left out as not visible, named by its id, label or class.
    public struct HiddenBranch: Equatable, Sendable {
        public var id: String?
        /// Masked and cut to 40 characters; nil for a secure field and never taken from an editable one.
        public var label: String?
        public var className: String?
        public var frame: UIFrame?

        public init(id: String?, label: String?, className: String?, frame: UIFrame?) {
            self.id = id
            self.label = label
            self.className = className
            self.frame = frame
        }

        /// With `label` masked and cut to 40 characters, as a presented view's label is shown.
        public static func shown(id: String?, label: String?, className: String?, frame: UIFrame?) -> HiddenBranch {
            let masked = label.map { SelectorText.truncated(LogRedactor.redact($0).text, limit: PresentationProbe.labelLimit) }
            return HiddenBranch(id: id, label: masked, className: className, frame: frame)
        }

        /// `id=drawer`, else the quoted label, else the class's short name, else `a branch`.
        public var name: String {
            if let id { return "id=" + UITreeRenderer.token(SelectorText.truncated(id, limit: PresentationProbe.labelLimit)) }
            if let label { return UITreeRenderer.quoted(label) }
            if let short = className?.split(separator: ".").last { return String(short) }
            return "a branch"
        }

        /// `id=drawer at (0, 0) 280x874`.
        public var summary: String {
            frame.map { "\(name) at \($0.summary)" } ?? name
        }
    }

    public var window: Window?
    public var keyboard: Bool
    public var logBox: LogBox?
    public var presented: Presented?
    public var staleFrame: StaleFrame?
    /// Branches Android's helper left out as not visible to the user, such as a panel slid off screen; nil when the source cannot say.
    public var hidden: Int?
    /// Up to five of them, on-screen and larger first; nil when the source does not name them.
    public var hiddenBranches: [HiddenBranch]?

    public init(
        window: Window? = nil, keyboard: Bool = false, logBox: LogBox? = nil, presented: Presented? = nil, staleFrame: StaleFrame? = nil,
        hidden: Int? = nil, hiddenBranches: [HiddenBranch]? = nil
    ) {
        self.window = window
        self.keyboard = keyboard
        self.logBox = logBox
        self.presented = presented
        self.staleFrame = staleFrame
        self.hidden = hidden
        self.hiddenBranches = hiddenBranches
    }

    public init(tree: UITree) {
        var window = tree.windows.flatMap(Self.window(in:)) ?? tree.systemPrompt?.window
        let logBox = KnownOverlays.logBox(in: tree)
        if let found = window, found.kind == .modal, found.package != nil, logBox == nil,
           found.title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true {
            window?.empty = KnownOverlays.isEmptyDialog(tree)
        }
        self.init(
            window: window,
            keyboard: tree.roots.contains { $0.flattened().contains { $0.role == .keyboard } },
            logBox: logBox,
            presented: tree.presented,
            staleFrame: tree.staleFrame,
            hidden: tree.hiddenBranches,
            hiddenBranches: tree.namedHiddenBranches
        )
    }

    /// The active window (else the focused one); a modal when an application window sits lower, or when it has no title.
    /// Android drops the windows beneath a touch-modal dialog, such as a React Native `Modal`, from the list, and an
    /// activity's window always carries its label, so an untitled application window is a dialog. A lone window is
    /// the helper's stand-in for an empty list, never a dialog.
    static func window(in windows: [UIWindowInfo]) -> Window? {
        guard let top = windows.first(where: \.active) ?? windows.first(where: \.focused) else { return nil }
        let kind: Window.Kind
        let untitled = top.title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true
        if top.kind == "system" {
            kind = .system
        } else if top.kind == "application",
                  windows.contains(where: { $0.id != top.id && $0.kind == "application" && $0.layer < top.layer }) || (untitled && windows.count > 1) {
            kind = .modal
        } else {
            kind = .app
        }
        return Window(title: top.title, kind: kind, package: top.package)
    }

    /// `# window: Lab Toggles (modal)` (`(modal, empty)` for an empty dialog), `# keyboard shown`, `# logbox: 2 logs`, `# presented: "Cancel" from PhotosPicker`, `# stale frame: ...` and `# hidden: 2 branches not visible to the user`, each only when it applies.
    public var headerLines: [String] {
        var lines: [String] = []
        if let window, window.kind != .app {
            lines.append("# window: \(window.title ?? window.package ?? "untitled") (\(window.kind.rawValue)\(window.empty ? ", empty" : ""))")
        }
        if keyboard {
            lines.append("# keyboard shown")
        }
        if let logBox {
            lines.append(logBox.inspector ? "# logbox: inspector open" : "# logbox: \(logBox.logs) log\(logBox.logs == 1 ? "" : "s")")
        }
        if let presented {
            lines.append("# presented: \(presented.summary)")
        }
        if let staleFrame {
            lines.append("# stale frame: \(staleFrame.name) is listed off screen at \(staleFrame.frame.summary), but the screen's centre is inside it; check a screenshot")
        }
        if let hidden, hidden > 0 {
            let named = (hiddenBranches ?? []).map(\.summary).joined(separator: "; ")
            lines.append("# hidden: \(hidden) branch\(hidden == 1 ? "" : "es") not visible to the user\(named.isEmpty ? "" : ": " + named)")
        }
        return lines
    }

    var jsonValue: OrderedJSON {
        .object([
            ("window", window.map { window in
                .object([
                    ("title", .optional(window.title, OrderedJSON.string)),
                    ("kind", .string(window.kind.rawValue)),
                    ("package", .optional(window.package, OrderedJSON.string)),
                    ("empty", .bool(window.empty)),
                ])
            } ?? .null),
            ("keyboard", .bool(keyboard)),
            ("logbox", logBox.map { .object([("logs", .integer($0.logs)), ("inspector", .bool($0.inspector))]) } ?? .null),
            ("presented", presented.map { presented in
                .object([
                    ("label", .optional(presented.label, OrderedJSON.string)),
                    ("role", .string(presented.role.rawValue)),
                    ("process", .optional(presented.process, OrderedJSON.string)),
                ])
            } ?? .null),
            ("staleFrame", staleFrame.map { stale in
                .object([
                    ("id", .optional(stale.id, OrderedJSON.string)),
                    ("label", .optional(stale.label, OrderedJSON.string)),
                    ("frame", stale.frame.jsonValue),
                ])
            } ?? .null),
            ("hidden", .optional(hidden, OrderedJSON.integer)),
            ("hiddenBranches", .optional(hiddenBranches) { branches in
                .array(branches.map { branch in
                    .object([
                        ("id", .optional(branch.id, OrderedJSON.string)),
                        ("label", .optional(branch.label, OrderedJSON.string)),
                        ("className", .optional(branch.className, OrderedJSON.string)),
                        ("frame", branch.frame.map(\.jsonValue) ?? .null),
                    ])
                })
            }),
        ])
    }
}

extension UITreeContext.Presented {
    /// `"Cancel" from PhotosPicker`, the role for an element with no label, and no process when it could not be read.
    public var summary: String {
        let shown = label.map(UITreeRenderer.quoted) ?? role.rawValue
        return process.map { "\(shown) from \($0)" } ?? shown
    }
}
