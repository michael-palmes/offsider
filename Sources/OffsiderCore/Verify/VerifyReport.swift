import Foundation

public enum ChangeKind: String, Codable, Sendable {
    case accessibilityTree = "accessibility-tree"
    case screenshot
    /// Android `button home`: the launcher came to the front.
    case activity
    /// The `--verify-id` element came on screen.
    case element
    case none
}

public struct VerifyReport: Equatable, Sendable {
    public static let schemaVersion = 2

    public let version: Int
    public let command: String
    public let target: String
    public let dispatched: DispatchState
    public let verified: Bool
    public let attempts: Int
    public let change: ChangeKind
    public let changes: [VerifyChange]
    public let changesTruncated: Int
    public let note: VerifyNote?
    public let style: TapDeliveryStyle?
    public let error: ErrorPayload?

    public init(
        command: String,
        target: String,
        dispatched: DispatchState,
        verified: Bool,
        attempts: Int,
        change: ChangeKind,
        changes: [VerifyChange] = [],
        changesTruncated: Int = 0,
        note: VerifyNote? = nil,
        style: TapDeliveryStyle? = nil,
        error: ErrorPayload? = nil
    ) {
        self.version = Self.schemaVersion
        self.command = command
        self.target = target
        self.dispatched = dispatched
        self.verified = verified
        self.attempts = attempts
        self.change = change
        self.changes = changes
        self.changesTruncated = changesTruncated
        self.note = note
        self.style = style
        self.error = error
    }

    public var exitCode: OffsiderExitCode {
        if let error { return error.exitCode }
        if verified { return .success }
        return dispatched == .yes ? .unverified : .failure
    }

    /// Keys in order: version, command, target, dispatched, verified, attempts, change, changes, changesTruncated, note, style, exitCode, error.
    public func jsonData() throws -> Data {
        let members: [(String, OrderedJSON)] = [
            ("version", .integer(version)),
            ("command", .string(command)),
            ("target", .string(target)),
            ("dispatched", .string(dispatched.rawValue)),
            ("verified", .bool(verified)),
            ("attempts", .integer(attempts)),
            ("change", .string(change.rawValue)),
            ("changes", .array(changes.map(\.jsonValue))),
            ("changesTruncated", .integer(changesTruncated)),
            ("note", .optional(note?.rawValue, OrderedJSON.string)),
            ("style", .optional(style?.rawValue, OrderedJSON.string)),
            ("exitCode", .integer(Int(exitCode.rawValue))),
            ("error", error.map(\.jsonValue) ?? .null),
        ]
        return Data(OrderedJSON.object(members).rendered().utf8)
    }
}
