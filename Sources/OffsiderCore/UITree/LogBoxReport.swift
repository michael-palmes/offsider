import Foundation

/// What `rn logbox status` reads: the toasts, bottom first, and whether the inspector is open.
public struct LogBoxState: Equatable, Sendable {
    public var toasts: [LogBoxToast]
    public var inspector: LogBoxInspector?

    public init(tree: UITree) {
        toasts = KnownOverlays.logBoxToasts(in: tree.roots, viewport: tree.viewport)
        inspector = KnownOverlays.logBoxInspector(in: tree.roots, viewport: tree.viewport)
    }

    public var logs: Int { toasts.reduce(0) { $0 + $1.count } }
    public var isEmpty: Bool { toasts.isEmpty && inspector == nil }

    public func jsonLine() -> String {
        OrderedJSON.object([
            ("version", .integer(1)),
            ("logs", .integer(inspector?.of ?? logs)),
            ("toasts", .array(toasts.map { toast in
                .object([("count", .integer(toast.count)), ("frame", toast.frame.jsonValue)])
            })),
            ("inspector", .bool(inspector != nil)),
        ]).rendered(compact: true)
    }

    public func textLine() -> String {
        if let inspector {
            return "LogBox inspector open" + (inspector.of.map { " (log \(inspector.log ?? 1) of \($0))" } ?? "")
        }
        guard !toasts.isEmpty else { return "No LogBox logs on screen" }
        return "LogBox: \(logs) log\(logs == 1 ? "" : "s") in \(toasts.count) toast\(toasts.count == 1 ? "" : "s")"
    }
}

/// What `rn logbox dismiss` did: logs cleared, logs left, and how.
public struct LogBoxDismissal: Equatable, Sendable {
    public enum Method: String, Sendable {
        case none
        case dismissButton = "dismiss-button"
        case inspector
    }

    public var cleared: Int
    public var remaining: Int
    public var method: Method

    public init(cleared: Int, remaining: Int, method: Method) {
        self.cleared = cleared
        self.remaining = remaining
        self.method = method
    }

    public func jsonLine() -> String {
        OrderedJSON.object([
            ("version", .integer(1)),
            ("cleared", .integer(cleared)),
            ("remaining", .integer(remaining)),
            ("method", .string(method.rawValue)),
        ]).rendered(compact: true)
    }
}
