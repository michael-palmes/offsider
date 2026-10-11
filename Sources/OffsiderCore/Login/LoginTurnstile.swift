import Foundation

/// What `login` reports about Turnstile. `tapped` means the checkbox was tapped and then read Success.
public enum LoginTurnstileStep: String, Equatable, Sendable {
    case off
    case absent
    case passed
    case tapped
}

/// The next Turnstile step from one read. `waitForWidget` runs the existing checkbox tap and wait.
public enum LoginTurnstilePlan: Equatable, Sendable {
    case done(LoginTurnstileStep)
    case waitForWidget
    case challenge
    case ambiguous(Int)
}

public enum LoginTurnstile {
    public static func plan(phase: TurnstilePhase, mode: LoginTurnstileMode) -> LoginTurnstilePlan {
        if mode == .off { return .done(.off) }
        switch phase {
        case .passed:
            return .done(.passed)
        case .absent:
            return mode == .required ? .waitForWidget : .done(.absent)
        case .ready, .checking:
            return .waitForWidget
        case .visualChallenge:
            return .challenge
        case .ambiguous(let count):
            return .ambiguous(count)
        }
    }
}

/// What `login` prints. It names the app, the login and its tags, never the username or the password.
public struct LoginReport: Equatable, Sendable {
    public var app: String
    public var key: String
    public var turnstile: LoginTurnstileStep
    public var submitLabel: String?
    /// The chosen login's tags.
    public var tags: [LoginTag]
    /// The `--where` tags that chose it, empty when none were passed.
    public var filter: [LoginTag]

    public init(app: String, key: String, turnstile: LoginTurnstileStep, submitLabel: String?, tags: [LoginTag] = [], filter: [LoginTag] = []) {
        self.app = app
        self.key = key
        self.turnstile = turnstile
        self.submitLabel = submitLabel
        self.tags = tags
        self.filter = filter
    }

    public func textLine() -> String {
        let button = submitLabel.map { "tapped \($0)" } ?? "tapped the submit button"
        let chosen = filter.isEmpty ? "" : " (chosen by --where \(filter.map(\.rawValue).joined(separator: " ")))"
        return "\(app) as \(LoginCredential.displayKey(key))\(chosen): filled the email or username field, filled the password field, \(button). The submit button was tapped. This does not mean the server accepted the login."
    }

    /// Version 1: keys are only ever added.
    public func jsonLine() -> String {
        var fields: [(String, OrderedJSON)] = [
            ("version", .integer(1)),
            ("app", .string(app)),
            ("key", .string(key)),
            ("identity", .string("filled")),
            ("password", .string("filled")),
            ("submitted", .bool(true)),
            ("name", .string(LoginCredential.displayKey(key))),
            ("tags", .array(tags.map { .string($0.rawValue) })),
        ]
        if !filter.isEmpty { fields.append(("where", .array(filter.map { .string($0.rawValue) }))) }
        return OrderedJSON.object(fields).rendered(compact: true)
    }
}
