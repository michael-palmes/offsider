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
    let candidates: [FailureCandidate]
    let coveredBy: CoverReport?
    let users: [FailureUser]

    init(
        errorDescription: String,
        reason: FailureReason = .commandFailed,
        hint: String? = nil,
        candidates: [FailureCandidate] = [],
        coveredBy: CoverReport? = nil,
        users: [FailureUser] = []
    ) {
        userFacingDescription = errorDescription
        self.reason = reason
        self.hint = hint
        self.candidates = candidates
        self.coveredBy = coveredBy
        self.users = users
    }

    static func deviceNotFound(id: String) -> CLIError {
        CLIError(
            errorDescription: "No device with ID \(id) was found. Run `offsider devices` to see available devices.",
            reason: .deviceNotFound,
            hint: "offsider devices"
        )
    }

    static func deviceNotBooted(id: String, state: String) -> CLIError {
        CLIError(
            errorDescription: "Simulator \(id) is not booted (\(state)).",
            reason: .deviceNotBooted,
            hint: "offsider boot \(id)"
        )
    }

    static func xcodeMissing(_ message: String) -> CLIError {
        CLIError(errorDescription: message, reason: .xcodeMissing, hint: XcodeSuggestion.current.select)
    }

    static func xcodeUnusable(_ message: String) -> CLIError {
        CLIError(errorDescription: message, reason: .xcodeUnusable, hint: XcodeSuggestion.current.select)
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

    /// A step only a person at the Mac may take: no terminal, or Touch ID or the password failed, was cancelled or is unavailable.
    static func personRequired(_ message: String, hint: String? = nil) -> CLIError {
        CLIError(errorDescription: message, reason: .personRequired, hint: hint)
    }

    /// A physical device the allow-list or managed policy refuses; only a person (or an administrator) can change that.
    static func deviceNotAllowed(name: String?, key: String, refusal: DeviceRefusal, audience: ErrorAudience = .current) -> CLIError {
        let device = name.map { "\($0) (\(key))" } ?? key
        let command = "offsider device-access allow"
        if refusal.isManaged {
            return CLIError(
                errorDescription: "\(device) is a physical device and \(refusal.explanation). Nothing was sent to it. Ask the administrator of this Mac.",
                reason: .deviceNotAllowed
            )
        }
        let again = refusal == .notAllowed ? "" : " again"
        let step = audience.personStep(command, agentTail: "\(again) and choose \(device); an agent cannot allow a device")
        return CLIError(
            errorDescription: "\(device) is a physical device and \(refusal.explanation), so nothing was sent to it.\(step)",
            reason: .deviceNotAllowed,
            hint: command
        )
    }

    static func internalError(_ message: String) -> CLIError {
        CLIError(errorDescription: message, reason: .internalError)
    }

    var failureMessage: String { userFacingDescription }
    var errorDescription: String? { userFacingDescription }
}

extension ProcessCaptureTimeoutError: UserFacingError {}
