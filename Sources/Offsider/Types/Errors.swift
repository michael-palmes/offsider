import Foundation
import OffsiderCore

// MARK: - Error Types
protocol UserFacingError: Error, CustomStringConvertible {
    var userFacingDescription: String { get }
}

extension UserFacingError {
    var description: String {
        userFacingDescription
    }
}

struct CLIError: LocalizedError, UserFacingError, OffsiderFailure {
    let userFacingDescription: String
    let reason: FailureReason
    let hint: String?

    init(errorDescription: String, reason: FailureReason = .commandFailed, hint: String? = nil) {
        userFacingDescription = errorDescription
        self.reason = reason
        self.hint = hint
    }

    static func deviceNotFound(id: String) -> CLIError {
        CLIError(
            errorDescription: "No device with ID \(id) was found. Run `offsider list-devices` to see available devices.",
            reason: .deviceNotFound,
            hint: "offsider list-devices"
        )
    }

    static func deviceNotBooted(id: String, state: String) -> CLIError {
        CLIError(
            errorDescription: "Simulator \(id) is not booted. Current state: \(state).",
            reason: .deviceNotBooted,
            hint: "xcrun simctl boot \(id)"
        )
    }

    static func xcodeMissing(_ message: String) -> CLIError {
        CLIError(errorDescription: message, reason: .xcodeMissing, hint: "xcode-select -s <Xcode.app>/Contents/Developer")
    }

    static func xcodeUnusable(_ message: String) -> CLIError {
        CLIError(errorDescription: message, reason: .xcodeUnusable, hint: "xcode-select -s <Xcode.app>/Contents/Developer")
    }

    static func notSupported(_ message: String) -> CLIError {
        CLIError(errorDescription: message, reason: .notSupported)
    }

    /// `command` cannot work on a physical iPhone or iPad; `alternative` says what to do instead.
    static func notOnPhone(command: String, device: String, alternative: String) -> CLIError {
        CLIError(
            errorDescription: "\(command) does not work on a physical iPhone or iPad, and \(device) is one. \(alternative)",
            reason: .notSupported
        )
    }

    /// Throws `notOnPhone` when `rawID` names a physical iPhone or iPad, before any device work.
    static func refuseOnPhone(_ rawID: String, command: String, alternative: String) throws {
        if case .iosDevice(let udid) = DeviceIDClassifier.classify(rawID) {
            throw notOnPhone(command: command, device: udid, alternative: alternative)
        }
    }

    static func internalError(_ message: String) -> CLIError {
        CLIError(errorDescription: message, reason: .internalError)
    }

    var failureMessage: String { userFacingDescription }
    var errorDescription: String? { userFacingDescription }
}

extension ProcessCaptureTimeoutError: UserFacingError {}
