import Foundation

/// What `login` saw of Turnstile before it tapped submit. Offsider never taps the widget, so it was absent or had already passed.
public enum LoginTurnstileStep: String, Equatable, Sendable {
    case absent
    case passed
}

/// How far `login` got with one field: `filled` once it typed there and read the field back.
public enum LoginFieldProgress: String, Equatable, Sendable {
    case filled
    case notFilled = "not_filled"
}

/// What `login` prints. It names the app, the login and its tags, never the username or the password.
public struct LoginReport: Equatable, Sendable {
    public var app: String
    public var key: String
    /// Nil when the login stopped before Turnstile was read.
    public var turnstile: LoginTurnstileStep?
    public var submitLabel: String?
    /// The chosen login's tags.
    public var tags: [LoginTag]
    /// The `--where` tags that chose it, empty when none were passed.
    public var filter: [LoginTag]
    public var identity: LoginFieldProgress = .filled
    public var password: LoginFieldProgress = .filled
    public var submitted = true
    /// Why a login that began typing stopped; nil once submit was tapped.
    public var error: ErrorPayload?
    /// True when the sign-in form was still in front once `login` stopped watching after submit; nil when the screen was not read then.
    public var formStillInFront: Bool?
    /// What became of a save-password prompt after submit; nil when none showed.
    public var savePrompt: SavePromptOutcome?
    /// True when `--wait-turnstile` waited for a person before the login went on.
    public var waitedForTurnstile = false

    public init(app: String, key: String, turnstile: LoginTurnstileStep?, submitLabel: String?, tags: [LoginTag] = [], filter: [LoginTag] = []) {
        self.app = app
        self.key = key
        self.turnstile = turnstile
        self.submitLabel = submitLabel
        self.tags = tags
        self.filter = filter
    }

    /// A login that stopped after it began typing, before submit was tapped.
    public static func stopped(app: String, key: String, identity: LoginFieldProgress, password: LoginFieldProgress) -> LoginReport {
        var report = LoginReport(app: app, key: key, turnstile: nil, submitLabel: nil)
        report.identity = identity
        report.password = password
        report.submitted = false
        return report
    }

    public var exitCode: OffsiderExitCode { error?.exitCode ?? .success }

    /// The sentence a stopped login's message ends with, nil when no field was filled.
    public var progressNote: String? {
        guard !submitted, identity == .filled else { return nil }
        return password == .filled ? "Both fields were filled." : "The email or username was filled."
    }

    public func textLine() -> String {
        let button = submitLabel.map { "tapped \($0)" } ?? "tapped the submit button"
        let chosen = filter.isEmpty ? "" : " (chosen by --where \(filter.map(\.rawValue).joined(separator: " ")))"
        return "\(app) as \(LoginCredential.displayKey(key))\(chosen): filled the email or username field, filled the password field, \(button). The submit button was tapped. \(serverNote)\(savePromptNote.map { " \($0)" } ?? "")"
    }

    /// The sentence a refused sign-in is told by: the form staying up is the only sign `login` has.
    public static let stillInFrontNote = "The sign-in form is still in front, so the app may have refused the login, or is slow. Read the screen before going on."

    var serverNote: String {
        formStillInFront == true ? Self.stillInFrontNote : "This does not mean the server accepted the login."
    }

    var savePromptNote: String? {
        switch savePrompt {
        case .declined: "Offsider declined the system's save-password prompt."
        case .closed: "A person closed the system's save-password prompt."
        case .open: "The system's save-password prompt is still up."
        case nil: nil
        }
    }

    /// Version 1: keys are only ever added.
    public func jsonLine() -> String {
        var fields: [(String, OrderedJSON)] = [
            ("version", .integer(1)),
            ("ok", .bool(error == nil)),
            ("app", .string(app)),
            ("key", .string(key)),
            ("identity", .string(identity.rawValue)),
            ("password", .string(password.rawValue)),
            ("submitted", .bool(submitted)),
            ("name", .string(LoginCredential.displayKey(key))),
            ("tags", .array(tags.map { .string($0.rawValue) })),
        ]
        if !filter.isEmpty { fields.append(("where", .array(filter.map { .string($0.rawValue) }))) }
        fields.append(("turnstile", .optional(turnstile) { .string($0.rawValue) }))
        fields.append(("formStillInFront", .optional(formStillInFront) { .bool($0) }))
        fields.append(("savePrompt", .optional(savePrompt) { .string($0.rawValue) }))
        fields.append(("waitedForTurnstile", .bool(waitedForTurnstile)))
        fields.append(("exitCode", .integer(Int(exitCode.rawValue))))
        fields.append(("error", .optional(error) { $0.jsonValue }))
        return OrderedJSON.object(fields).rendered(compact: true)
    }
}
