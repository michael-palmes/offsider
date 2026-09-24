import Foundation

public enum ChangeKind: String, Codable, Sendable {
    case accessibilityTree = "accessibility-tree"
    case screenshot
    case none
}

public struct VerifyReport: Codable, Equatable, Sendable {
    public static let schemaVersion = 1

    public let version: Int
    public let command: String
    public let target: String
    public let dispatched: Bool
    public let verified: Bool
    public let attempts: Int
    public let change: ChangeKind
    public let style: TapDeliveryStyle?
    public let error: String?

    public init(
        command: String,
        target: String,
        dispatched: Bool,
        verified: Bool,
        attempts: Int,
        change: ChangeKind,
        style: TapDeliveryStyle? = nil,
        error: String? = nil
    ) {
        self.version = Self.schemaVersion
        self.command = command
        self.target = target
        self.dispatched = dispatched
        self.verified = verified
        self.attempts = attempts
        self.change = change
        self.style = style
        self.error = error
    }

    public var exitCode: OffsiderExitCode {
        if error != nil { return .failure }
        if verified { return .success }
        return dispatched ? .unverified : .failure
    }

    public func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    private enum CodingKeys: String, CodingKey {
        case version, command, target, dispatched, verified, attempts, change, style, error
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(command, forKey: .command)
        try container.encode(target, forKey: .target)
        try container.encode(dispatched, forKey: .dispatched)
        try container.encode(verified, forKey: .verified)
        try container.encode(attempts, forKey: .attempts)
        try container.encode(change, forKey: .change)
        try container.encode(style, forKey: .style)
        try container.encode(error, forKey: .error)
    }
}
