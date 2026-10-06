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

        public init(title: String?, kind: Kind, package: String?) {
            self.title = title
            self.kind = kind
            self.package = package
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

    public var window: Window?
    public var keyboard: Bool
    public var logBox: LogBox?

    public init(window: Window? = nil, keyboard: Bool = false, logBox: LogBox? = nil) {
        self.window = window
        self.keyboard = keyboard
        self.logBox = logBox
    }

    public init(tree: UITree) {
        self.init(
            window: tree.windows.flatMap(Self.window(in:)),
            keyboard: tree.roots.contains { $0.flattened().contains { $0.role == .keyboard } },
            logBox: KnownOverlays.logBox(in: tree)
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

    /// `# window: Lab Toggles (modal)`, `# keyboard shown` and `# logbox: 2 logs`, each only when it applies.
    public var headerLines: [String] {
        var lines: [String] = []
        if let window, window.kind != .app {
            lines.append("# window: \(window.title ?? window.package ?? "untitled") (\(window.kind.rawValue))")
        }
        if keyboard {
            lines.append("# keyboard shown")
        }
        if let logBox {
            lines.append(logBox.inspector ? "# logbox: inspector open" : "# logbox: \(logBox.logs) log\(logBox.logs == 1 ? "" : "s")")
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
                ])
            } ?? .null),
            ("keyboard", .bool(keyboard)),
            ("logbox", logBox.map { .object([("logs", .integer($0.logs)), ("inspector", .bool($0.inspector))]) } ?? .null),
        ])
    }
}
