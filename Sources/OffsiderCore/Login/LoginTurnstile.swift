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

/// What `login` prints. It names the app and the key, never the username or the password.
public struct LoginReport: Equatable, Sendable {
    public var app: String
    public var key: String
    public var turnstile: LoginTurnstileStep
    public var submitLabel: String?

    public init(app: String, key: String, turnstile: LoginTurnstileStep, submitLabel: String?) {
        self.app = app
        self.key = key
        self.turnstile = turnstile
        self.submitLabel = submitLabel
    }

    public func textLine() -> String {
        let button = submitLabel.map { "tapped \($0)" } ?? "tapped the submit button"
        return "\(app) key \(key): filled the email or username field, filled the password field, \(button). The submit button was tapped. This does not mean the server accepted the login."
    }

    public func jsonLine() -> String {
        OrderedJSON.object([
            ("version", .integer(1)),
            ("app", .string(app)),
            ("key", .string(key)),
            ("identity", .string("filled")),
            ("password", .string("filled")),
            ("submitted", .bool(true)),
        ]).rendered(compact: true)
    }
}
