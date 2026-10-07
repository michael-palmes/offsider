import Foundation
import OffsiderCore

/// Every physical iOS device failure a user can see; each message says what happened and what to do next.
public struct IOSDeviceError: LocalizedError, CustomStringConvertible, Equatable, Sendable {
    public enum Kind: String, Equatable, Sendable {
        case notYetSupported
        case xcodeMissing
        case devicectlFailed
        case notListed
        case unavailable
        case notWired
        case untrusted
        case developerModeOff
        case preparing
        case usbmuxUnavailable
        case usbmuxFailed
        case runnerUnavailable
        case locked
        case uiAutomationOff
        case xcodeTooOld
        case notSupported
        case unsupportedButton
        case hidFailed
        case runnerBuildFailed
        case runnerFailed
        case teamMissing
        case noFocusedField
        case secureFieldRefused
        case streamFailed
        case streamNeedsGUISession
        case sessionFailed
        case sessionLost
    }

    public let kind: Kind
    public let message: String
    /// Overrides the hint read from the message, for one that names a file rather than a command.
    public let explicitHint: String?

    public init(_ kind: Kind, _ message: String, hint: String? = nil) {
        self.kind = kind
        self.message = message
        self.explicitHint = hint
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
            "The developer services on \(name) are not available, so Xcode may still be preparing it for development. Keep it connected and unlocked until that finishes, then retry; `offsider doctor --device \(udid)` shows its state."
        )
    }
}

extension IOSDeviceError {
    /// A failure listing devices or opening a stream through usbmuxd.
    public static func usbmux(_ error: UsbmuxError, udid: String) -> IOSDeviceError {
        switch error {
        case .socketUnavailable(let detail):
            return IOSDeviceError(.usbmuxUnavailable, "usbmuxd, which reaches iPhones over USB, is not answering (\(detail)). Reconnect the cable; restart the Mac if it persists.")
        case .timedOut:
            return IOSDeviceError(.usbmuxUnavailable, "usbmuxd, which reaches iPhones over USB, did not answer in time. Reconnect the cable; restart the Mac if it persists.")
        case .notOnUSB:
            return .notWired(udid)
        case .notAttached, .result(2):
            return IOSDeviceError(.unavailable, "\(udid) is not attached over USB. Connect its cable and unlock it, then run `offsider list-devices`.")
        case .result(3):
            return runnerNotListening(udid)
        case .result(let number):
            return IOSDeviceError(.usbmuxFailed, "usbmuxd refused the request for \(udid) (result \(number)). Run `offsider doctor --device \(udid)`.")
        case .closed, .malformed:
            return IOSDeviceError(.usbmuxFailed, "usbmuxd sent a reply Offsider could not read for \(udid). Run `offsider doctor --device \(udid)`.")
        }
    }

    /// usbmuxd answers without a USB row for a wired device; its list can go stale until the cable is replugged.
    public static func notOnUsbmux(_ name: String) -> IOSDeviceError {
        IOSDeviceError(.usbmuxUnavailable, "usbmuxd does not list \(name) on USB, so Offsider cannot reach its runner. Unplug and replug the cable, then retry.")
    }

    /// xcodebuild's device preparation waits for an unlock, so the runner cannot start until the user unlocks the device.
    static func runnerLocked(_ name: String) -> IOSDeviceError {
        IOSDeviceError(.locked, "\(name) is locked, so Xcode cannot start the Offsider runner. Unlock it, then retry; Offsider never types a passcode.")
    }

    /// XCTest could not enable UI automation, most often because the device's passcode prompt for XCTest went unanswered.
    static func runnerAutomationBlocked(_ name: String) -> IOSDeviceError {
        IOSDeviceError(
            .uiAutomationOff,
            "XCTest could not enable UI automation on \(name), so the Offsider runner cannot start. If the device shows \"Enter Passcode for \"XCTest\"\", ask the user to enter it on the device; otherwise check Settings > Developer > UI Automation. Then retry; Offsider never types a passcode."
        )
    }

    /// A failure on the stream to the device runner, after usbmuxd connected it; nothing was sent to the app.
    public static func runner(_ error: UsbmuxError, udid: String) -> IOSDeviceError {
        switch error {
        case .timedOut:
            return IOSDeviceError(.runnerUnavailable, "The runner on \(udid) did not answer in time, so no input was sent. Retry; if it persists, run `offsider doctor --device \(udid)`.")
        case .socketUnavailable, .notOnUSB, .notAttached, .result:
            return usbmux(error, udid: udid)
        case .closed, .malformed:
            return IOSDeviceError(.runnerUnavailable, "The runner on \(udid) closed the connection or sent a reply Offsider could not read, so no input was sent. Retry; if it persists, run `offsider doctor --device \(udid)`.")
        }
    }

    static func runnerNotListening(_ udid: String) -> IOSDeviceError {
        IOSDeviceError(.runnerUnavailable, "Nothing on \(udid) accepted the runner connection, so no input was sent. Retry; if it persists, run `offsider doctor --device \(udid)`.")
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
        case .usbmuxUnavailable: return .usbmuxUnavailable
        case .usbmuxFailed: return .commandFailed
        case .runnerUnavailable: return .runnerUnavailable
        case .locked: return .deviceLocked
        case .uiAutomationOff: return .uiAutomationOff
        case .xcodeTooOld: return .xcodeTooOld
        case .notSupported: return .notSupported
        case .unsupportedButton: return .unsupportedButton
        case .hidFailed: return .inputFailed
        case .runnerBuildFailed: return .runnerBuildFailed
        case .runnerFailed: return .treeReadFailed
        case .teamMissing: return .teamMissing
        case .noFocusedField: return .noFocusedField
        case .secureFieldRefused: return .securePasteRefused
        case .streamFailed: return .screenshotFailed
        case .streamNeedsGUISession: return .notSupported
        case .sessionFailed: return .hidBrokerFailed
        case .sessionLost: return .inputOutcomeUnknown
        }
    }

    public var failureMessage: String { message }

    /// The message's first backticked Offsider or xcode-select command.
    public var hint: String? {
        if let explicitHint { return explicitHint }
        let quoted = message.split(separator: "`", omittingEmptySubsequences: false).enumerated().filter { $0.offset % 2 == 1 }
        return quoted.map { String($0.element) }.first { $0.hasPrefix("offsider ") || $0.hasPrefix("xcode-select ") }
    }
}
