import Foundation

/// The JSON `error` object: `reason`, `message`, `hint`, `dispatched`, `candidates`.
public struct ErrorPayload: Equatable, Sendable {
    public static let maxCandidates = 5

    public let reason: FailureReason
    public let message: String
    public let hint: String?
    /// Nil for commands that send no input.
    public let dispatched: DispatchState?
    public let candidates: [FailureCandidate]
    /// What a refused tap would have landed on; only `target_covered` carries it.
    public let coveredBy: CoverReport?

    public init(reason: FailureReason, message: String, hint: String? = nil, dispatched: DispatchState? = nil, candidates: [FailureCandidate] = [], coveredBy: CoverReport? = nil) {
        self.reason = reason
        self.message = message
        self.hint = hint
        self.dispatched = dispatched
        self.candidates = Array(candidates.prefix(Self.maxCandidates))
        self.coveredBy = coveredBy
    }

    public init(_ failure: any OffsiderFailure, dispatched: DispatchState? = nil) {
        self.init(reason: failure.reason, message: failure.failureMessage, hint: failure.hint, dispatched: dispatched, candidates: failure.candidates, coveredBy: failure.coveredBy)
    }

    public var exitCode: OffsiderExitCode { reason.exitCode }

    /// The same payload with `scrub` applied to the message and hint.
    public func scrubbed(_ scrub: (String) -> String) -> ErrorPayload {
        ErrorPayload(reason: reason, message: scrub(message), hint: hint.map(scrub), dispatched: dispatched, candidates: candidates, coveredBy: coveredBy)
    }

    var jsonValue: OrderedJSON {
        var members: [(String, OrderedJSON)] = [
            ("reason", .string(reason.rawValue)),
            ("message", .string(message)),
            ("hint", .optional(hint, OrderedJSON.string)),
            ("dispatched", .optional(dispatched?.rawValue, OrderedJSON.string)),
            ("candidates", .array(candidates.map(\.jsonValue))),
        ]
        if let coveredBy {
            members.append(("coveredBy", coveredBy.jsonValue))
        }
        return .object(members)
    }

    public func jsonLine() -> String {
        jsonValue.rendered(compact: true)
    }
}

/// What a `--json` command prints on stdout when it fails without a report of its own.
public struct ErrorEnvelope: Equatable, Sendable {
    public static let schemaVersion = 1

    public let command: String?
    public let error: ErrorPayload

    public init(command: String?, error: ErrorPayload) {
        self.command = command
        self.error = error
    }

    public var exitCode: OffsiderExitCode { error.exitCode }

    public func jsonLine() -> String {
        OrderedJSON.object([
            ("version", .integer(Self.schemaVersion)),
            ("ok", .bool(false)),
            ("command", .optional(command, OrderedJSON.string)),
            ("exitCode", .integer(Int(exitCode.rawValue))),
            ("error", error.jsonValue),
        ]).rendered(compact: true)
    }
}
