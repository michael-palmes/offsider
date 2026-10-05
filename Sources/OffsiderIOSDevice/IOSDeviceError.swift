import Foundation
import OffsiderCore

/// Every physical iOS device failure a user can see; each message says what happened and what to do next.
public struct IOSDeviceError: LocalizedError, CustomStringConvertible, Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case notYetSupported
    }

    public let kind: Kind
    public let message: String

    public init(_ kind: Kind, _ message: String) {
        self.kind = kind
        self.message = message
    }

    public var errorDescription: String? { message }
    public var description: String { message }

    static func notYetSupported(_ udid: String, feature: String) -> IOSDeviceError {
        IOSDeviceError(
            .notYetSupported,
            "\(feature) on a physical iPhone or iPad is not available in this version of Offsider, and \(udid) is one. Use an iOS simulator from `offsider list-devices`."
        )
    }
}

extension IOSDeviceError: OffsiderFailure {
    public var reason: FailureReason {
        switch kind {
        case .notYetSupported: return .notSupported
        }
    }

    public var failureMessage: String { message }

    /// The message's first backticked Offsider or xcrun command.
    public var hint: String? {
        let parts = message.split(separator: "`", omittingEmptySubsequences: false)
        guard parts.count >= 3 else { return nil }
        let command = String(parts[1])
        return command.hasPrefix("offsider ") || command.hasPrefix("xcrun ") ? command : nil
    }
}
