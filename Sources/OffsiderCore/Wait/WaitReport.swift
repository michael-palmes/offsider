import Foundation

/// What `wait --json` and `assert --json` print: one compact object.
public struct WaitReport: Equatable, Sendable {
    public let outcome: WaitOutcome

    public init(_ outcome: WaitOutcome) {
        self.outcome = outcome
    }

    /// `{"met":true,"elapsedMs":1200,"reason":"on screen","match":{...},"matched":null,"nearest":[]}`; `nearest` lists near misses after a not-found timeout.
    public func jsonLine() -> String {
        OrderedJSON.object([
            ("met", .bool(outcome.met)),
            ("elapsedMs", .integer(Int((outcome.elapsed * 1000).rounded()))),
            ("reason", .string(outcome.reason)),
            ("match", .optional(outcome.match) { .object($0.jsonFields) }),
            ("matched", .optional(outcome.matched) { .object([("by", .string($0.by)), ("text", .string($0.text))]) }),
            ("nearest", Self.nearest(outcome)),
        ]).rendered(compact: true)
    }

    static func nearest(_ outcome: WaitOutcome) -> OrderedJSON {
        .array((outcome.nearMiss?.candidates ?? []).map(\.jsonValue))
    }
}
