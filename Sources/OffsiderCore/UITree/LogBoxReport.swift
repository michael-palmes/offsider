import Foundation

/// What `rn logbox status` reads: the toasts, bottom first, whether the inspector is open, and the window around them.
public struct LogBoxState: Equatable, Sendable {
    public var toasts: [LogBoxToast]
    public var inspector: LogBoxInspector?
    /// The active window, on Android only.
    public var window: UITreeContext.Window?

    public init(tree: UITree) {
        toasts = KnownOverlays.logBoxToasts(in: tree.roots, viewport: tree.viewport)
        inspector = KnownOverlays.logBoxInspector(in: tree.roots, viewport: tree.viewport)
        window = tree.context.window
    }

    /// A modal window is up, which on Android hides the app's toasts: the inspector, or its dialog before it draws.
    public var modal: Bool { window?.kind == .modal }

    /// The empty dialog React Native can leave up after its last log.
    public var emptyDialog: Bool { window?.empty == true }

    public var logs: Int { toasts.reduce(0) { $0 + $1.count } }
    public var isEmpty: Bool { toasts.isEmpty && inspector == nil }

    /// The toast numbered `index` from the bottom, if there is one.
    public func toast(_ index: Int) -> LogBoxToast? {
        toasts.first { $0.index == index }
    }

    /// Each toast's message as shown: redacted unless `redacts` is false.
    public static func shown(_ message: String, redacts: Bool) -> String {
        redacts ? LogRedactor.redact(message).text : message
    }

    /// `shown` on one line for text output, with control and bidi characters escaped and long messages cut.
    public static func shownLine(_ message: String, redacts: Bool) -> String {
        TerminalText.line(shown(message, redacts: redacts))
    }

    public func jsonLine(redacts: Bool = true) -> String {
        OrderedJSON.object([
            ("version", .integer(1)),
            ("logs", .integer(inspector?.of ?? logs)),
            ("toasts", .array(toasts.map { toast in
                .object([
                    ("index", .integer(toast.index)),
                    ("count", .integer(toast.count)),
                    ("message", .string(Self.shown(toast.message, redacts: redacts))),
                    ("frame", toast.frame.jsonValue),
                ])
            })),
            ("inspector", .bool(inspector != nil)),
            ("emptyDialog", .bool(emptyDialog)),
        ]).rendered(compact: true)
    }

    /// One summary line, then one line per toast, bottom first: `  1. <message>`, with its log count when above 1.
    public func text(redacts: Bool = true) -> String {
        if let inspector {
            return "LogBox inspector open" + (inspector.of.map { " (log \(inspector.log ?? 1) of \($0))" } ?? "")
        }
        guard !toasts.isEmpty else {
            return emptyDialog ? "No LogBox logs on screen, but an empty dialog covers the app, as React Native can leave its LogBox dialog" : "No LogBox logs on screen"
        }
        let head = "LogBox: \(logs) log\(logs == 1 ? "" : "s") in \(toasts.count) toast\(toasts.count == 1 ? "" : "s"), bottom first"
        let lines = toasts.map { toast in
            "  \(toast.index). \(Self.shownLine(toast.message, redacts: redacts))" + (toast.count > 1 ? " (\(toast.count) logs)" : "")
        }
        return ([head] + lines).joined(separator: "\n")
    }
}

/// What `rn logbox dismiss` did: logs cleared, logs left, how, and whether React Native's empty LogBox dialog stayed over the app.
public struct LogBoxDismissal: Equatable, Sendable {
    public enum Method: String, Sendable {
        case none
        case dismissButton = "dismiss-button"
        case inspector
    }

    public var cleared: Int
    public var remaining: Int
    public var method: Method
    public var emptyDialog: Bool

    public init(cleared: Int, remaining: Int, method: Method, emptyDialog: Bool = false) {
        self.cleared = cleared
        self.remaining = remaining
        self.method = method
        self.emptyDialog = emptyDialog
    }

    /// No log is left and nothing covers the app.
    public var isClear: Bool { remaining == 0 && !emptyDialog }

    public func jsonLine() -> String {
        OrderedJSON.object([
            ("version", .integer(1)),
            ("cleared", .integer(cleared)),
            ("remaining", .integer(remaining)),
            ("method", .string(method.rawValue)),
            ("emptyDialog", .bool(emptyDialog)),
        ]).rendered(compact: true)
    }
}

/// What `rn logbox open` did: the toast it tapped (nil when the inspector was already open) and the inspector it shows.
public struct LogBoxOpening: Equatable, Sendable {
    public var toast: LogBoxToast?
    public var inspector: LogBoxInspector

    public init(toast: LogBoxToast?, inspector: LogBoxInspector) {
        self.toast = toast
        self.inspector = inspector
    }

    public func jsonLine(redacts: Bool) -> String {
        let index: OrderedJSON = toast.map { .integer($0.index) } ?? .null
        let message: OrderedJSON = toast.map { .string(LogBoxState.shown($0.message, redacts: redacts)) } ?? .null
        let log: OrderedJSON = inspector.log.map { .integer($0) } ?? .null
        let of: OrderedJSON = inspector.of.map { .integer($0) } ?? .null
        return OrderedJSON.object([("version", .integer(1)), ("index", index), ("message", message), ("log", log), ("of", of)]).rendered(compact: true)
    }

    public func textLine(redacts: Bool) -> String {
        let position = inspector.of.map { ": log \(inspector.log ?? 1) of \($0)" } ?? ""
        guard let toast else { return "LogBox inspector already open\(position)" }
        return "✓ Opened LogBox toast \(toast.index) (\(LogBoxState.shownLine(toast.message, redacts: redacts)))\(position)"
    }
}
