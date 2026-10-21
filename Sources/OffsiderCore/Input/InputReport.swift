import Foundation

/// One `--json` line for an input command run without `--verify`: whether the input was sent, never whether it took effect.
public struct InputReport: Equatable, Sendable {
    public static let schemaVersion = 1

    public let command: String
    /// The caller's own words for what the input went to, such as `id=save` or `(120, 640)`; never typed text.
    public let target: String
    public let dispatched: DispatchState
    /// Where a tap landed, or on a failure aimed, in points.
    public var point: UIPoint?
    /// The percentage a slider reached.
    public var percent: Double?
    /// The slider's value as its accessibility element reads it.
    public var value: String?
    /// From the command's start to the report, in seconds.
    public let elapsed: TimeInterval
    public let error: ErrorPayload?

    public init(
        command: String, target: String, dispatched: DispatchState,
        point: UIPoint? = nil, percent: Double? = nil, value: String? = nil,
        elapsed: TimeInterval = 0, error: ErrorPayload? = nil
    ) {
        self.command = command
        self.target = target
        self.dispatched = dispatched
        self.point = point
        self.percent = percent
        self.value = value
        self.elapsed = elapsed
        self.error = error
    }

    public var ok: Bool { error == nil }
    public var exitCode: OffsiderExitCode { error?.exitCode ?? .success }

    /// The slider's value and the error's text.
    static let untrustedPaths = ["value"] + UntrustedPaths.under("error", UntrustedPaths.errorFields)

    public func jsonLine() -> String {
        var members: [(String, OrderedJSON)] = [
            ("version", .integer(Self.schemaVersion)),
            ("ok", .bool(ok)),
            ("command", .string(command)),
            ("target", .string(target)),
            ("dispatched", .string(dispatched.rawValue)),
        ]
        if let point {
            members.append(("point", .object([("x", .number(Self.rounded(point.x))), ("y", .number(Self.rounded(point.y)))])))
        }
        if let percent { members.append(("percent", .number(Self.rounded(percent)))) }
        if let value { members.append(("value", .string(value))) }
        members += [
            ("elapsedMs", .integer(VerifyPhases.milliseconds(elapsed))),
            ("exitCode", .integer(Int(exitCode.rawValue))),
            ("error", error.map(\.jsonValue) ?? .null),
        ]
        return UntrustedPaths.marked(.object(members), Self.untrustedPaths).rendered(compact: true)
    }

    /// To 0.01, the precision of describe-ui frames.
    private static func rounded(_ value: Double) -> Double {
        (value * 100).rounded() / 100
    }
}
