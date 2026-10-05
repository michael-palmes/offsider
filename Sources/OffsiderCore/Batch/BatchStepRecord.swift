import Foundation

/// One `batch --json` line for a finished step.
///
/// Keys in order: `step`, `kind`, `line`, `ok`, `ms`; a failure adds `exitCode` and `error`; then the step's own keys:
/// `wait` and `assert` add `met`, `reason`, `match`, `matched`; `screenshot` adds its report keys;
/// `describe-ui` adds `tree` for json or `output` for ndjson and text.
public struct BatchStepRecord: Sendable {
    public enum Detail: Sendable {
        case none
        case wait(WaitOutcome)
        case screenshot(ScreenshotReport)
        case describe(UITree, UITreeRenderOptions)
    }

    public struct Failure: Equatable, Sendable {
        public let error: ErrorPayload

        public init(error: ErrorPayload) {
            self.error = error
        }

        public var exitCode: Int32 { error.exitCode.rawValue }
        public var message: String { error.message }

        /// The condition was checked and not met (exit 5), rather than the step failing to run.
        public var isConditionNotMet: Bool {
            error.exitCode == .unverified
        }
    }

    /// One-based.
    public let step: Int
    public let kind: String
    public let line: String
    public let elapsed: TimeInterval
    public let failure: Failure?
    public let detail: Detail

    public init(step: Int, kind: String, line: String, elapsed: TimeInterval, failure: Failure?, detail: Detail = .none) {
        self.step = step
        self.kind = kind
        self.line = line
        self.elapsed = elapsed
        self.failure = failure
        self.detail = detail
    }

    public var ok: Bool { failure == nil }

    public func jsonLine() -> String {
        var members: [(String, OrderedJSON)] = [
            ("step", .integer(step)),
            ("kind", .string(kind)),
            ("line", .string(line)),
            ("ok", .bool(ok)),
            ("ms", .integer(Self.milliseconds(elapsed))),
        ]
        if let failure {
            members += [("exitCode", .integer(Int(failure.exitCode))), ("error", failure.error.jsonValue)]
        }
        switch detail {
        case .none:
            break
        case .wait(let outcome):
            members += [
                ("met", .bool(outcome.met)),
                ("reason", .string(outcome.reason)),
                ("match", .optional(outcome.match) { .object($0.jsonFields) }),
                ("matched", .optional(outcome.matched) { .object([("by", .string($0.by)), ("text", .string($0.text))]) }),
            ]
        case .screenshot(let report):
            members += report.jsonMembers
        case .describe(let tree, let options):
            if options.format == .json {
                members.append(("tree", UITreeRenderer.json(tree, options, fields: options.fields.map(Set.init))))
            } else {
                members.append(("output", .string(String(decoding: UITreeRenderer.render(tree, options), as: UTF8.self))))
            }
        }
        return OrderedJSON.object(members).rendered(compact: true)
    }

    /// The final `batch --json` line: `{"step":null,"kind":"batch","ok":true,"ms":840,"steps":5,"failed":0,"dispatched":"yes"}`.
    public static func summaryLine(ok: Bool, elapsed: TimeInterval, steps: Int, failed: Int, dispatched: DispatchState) -> String {
        OrderedJSON.object([
            ("step", .null),
            ("kind", .string("batch")),
            ("ok", .bool(ok)),
            ("ms", .integer(milliseconds(elapsed))),
            ("steps", .integer(steps)),
            ("failed", .integer(failed)),
            ("dispatched", .string(dispatched.rawValue)),
        ]).rendered(compact: true)
    }

    /// Whether any of a batch's steps sent input: `yes` beats `unknown` beats `no`.
    public static func dispatched(_ states: [DispatchState]) -> DispatchState {
        if states.contains(.yes) { return .yes }
        return states.contains(.unknown) ? .unknown : .no
    }

    private static func milliseconds(_ seconds: TimeInterval) -> Int {
        Int((seconds * 1000).rounded())
    }
}
