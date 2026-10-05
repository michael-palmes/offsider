import Foundation
import OffsiderCore

/// Every physical iOS device failure a user can see; each message says what happened and what to do next.
public struct IOSDeviceError: LocalizedError, CustomStringConvertible, Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case notYetSupported
        case xcodeMissing
        case devicectlFailed
        case notListed
        case unavailable
        case notWired
        case untrusted
        case developerModeOff
        case preparing
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

    static func xcodeMissing(_ detail: String) -> IOSDeviceError {
        IOSDeviceError(.xcodeMissing, "No usable Xcode is selected: \(detail). Select one with `xcode-select -s <Xcode.app>/Contents/Developer`.")
    }

    static func devicectlFailed(_ command: String, udid: String?, detail: String) -> IOSDeviceError {
        let reason = detail.isEmpty ? "" : ": \(detail)"
        let next = udid.map { "Run `offsider doctor --device \($0)` to check the device." } ?? "Run `offsider doctor` to check Xcode."
        return IOSDeviceError(.devicectlFailed, "`devicectl \(command)` failed\(reason). \(next)")
    }

    static func notListed(_ udid: String) -> IOSDeviceError {
        IOSDeviceError(
            .notListed,
            "No iPhone or iPad with UDID \(udid) is known to this Mac. Connect it with a cable, unlock it and trust this Mac, then run `offsider list-devices`."
        )
    }

    static func unavailable(_ name: String) -> IOSDeviceError {
        IOSDeviceError(.unavailable, "\(name) is paired with this Mac but not connected. Connect its cable and unlock it, then run `offsider list-devices`.")
    }

    static func notWired(_ name: String) -> IOSDeviceError {
        IOSDeviceError(.notWired, "\(name) is connected over Wi-Fi, and Offsider drives iPhones and iPads over USB only. Connect its cable, then retry.")
    }

    static func untrusted(_ name: String) -> IOSDeviceError {
        IOSDeviceError(.untrusted, "\(name) does not trust this Mac. Unlock it and tap Trust when it asks, then retry.")
    }

    static func developerModeOff(_ name: String) -> IOSDeviceError {
        IOSDeviceError(
            .developerModeOff,
            "Developer Mode is off on \(name). Turn it on in Settings > Privacy & Security > Developer Mode, restart the device, then retry."
        )
    }

    static func preparing(_ name: String, udid: String) -> IOSDeviceError {
        IOSDeviceError(
            .preparing,
            "Xcode is still preparing \(name) for development. Keep it connected and unlocked until that finishes, then retry; `offsider doctor --device \(udid)` shows its state."
        )
    }
}

extension IOSDeviceError: OffsiderFailure {
    public var reason: FailureReason {
        switch kind {
        case .notYetSupported: return .notSupported
        case .xcodeMissing: return .xcodeMissing
        case .devicectlFailed: return .commandFailed
        case .notListed, .unavailable: return .deviceNotFound
        case .notWired: return .deviceNotWired
        case .untrusted: return .deviceUntrusted
        case .developerModeOff: return .developerModeOff
        case .preparing: return .devicePreparing
        }
    }

    public var failureMessage: String { message }

    /// The message's first backticked Offsider or xcode-select command.
    public var hint: String? {
        let quoted = message.split(separator: "`", omittingEmptySubsequences: false).enumerated().filter { $0.offset % 2 == 1 }
        return quoted.map { String($0.element) }.first { $0.hasPrefix("offsider ") || $0.hasPrefix("xcode-select ") }
    }
}
