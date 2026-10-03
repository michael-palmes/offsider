import Foundation

/// What `wait --json` and `assert --json` print: one compact object.
public struct WaitReport: Equatable, Sendable {
    public let outcome: WaitOutcome

    public init(_ outcome: WaitOutcome) {
        self.outcome = outcome
    }

    /// `{"met":true,"elapsedMs":1200,"reason":"on screen","match":{...}}`; `match` is null unless one element matched.
    public func jsonLine() -> String {
        OrderedJSON.object([
            ("met", .bool(outcome.met)),
            ("elapsedMs", .integer(Int((outcome.elapsed * 1000).rounded()))),
            ("reason", .string(outcome.reason)),
            ("match", .optional(outcome.match) { .object($0.jsonFields) }),
        ]).rendered(compact: true)
    }
}
