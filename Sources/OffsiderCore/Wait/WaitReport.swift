import Foundation

/// What `wait --json` and `assert --json` print: one compact object.
public struct WaitReport: Equatable, Sendable {
    public let outcome: WaitOutcome

    public init(_ outcome: WaitOutcome) {
        self.outcome = outcome
    }

    /// `{"met":true,"elapsedMs":1200,"reason":"on screen","match":{...},"matched":null}`; `match` is null unless one element matched, `matched` unless `wait --any` was met.
    public func jsonLine() -> String {
        OrderedJSON.object([
            ("met", .bool(outcome.met)),
            ("elapsedMs", .integer(Int((outcome.elapsed * 1000).rounded()))),
            ("reason", .string(outcome.reason)),
            ("match", .optional(outcome.match) { .object($0.jsonFields) }),
            ("matched", .optional(outcome.matched) { .object([("by", .string($0.by)), ("text", .string($0.text))]) }),
        ]).rendered(compact: true)
    }
}
