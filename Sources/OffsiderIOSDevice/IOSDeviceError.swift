import Foundation
import OffsiderCore

/// Every physical iOS device failure a user can see; each message says what happened and what to do next.
extension IOSDeviceError {
    /// Why sign-in text cannot go as key presses; never holds the text.
    static func keysOnlyRefusal(_ text: String, device: DeviceID) -> IOSDeviceError {
        guard TextToHIDEvents.validateText(text) else {
            return IOSDeviceError(.notSupported, "Offsider signs in on \(device.rawValue) with US keyboard keys, and this login has a character they cannot type. Nothing was typed. Use a test password with plain letters, digits and symbols.")
        }
        return .notSupportedOnDevice(
            "Signing in without the device session",
            instead: "Retry once `offsider doctor --device \(device.rawValue)` passes. It needs Xcode 27 and a logged-in desktop on this Mac."
        )
    }
}

public struct IOSDeviceError: LocalizedError, CustomStringConvertible, Equatable, Sendable {
    public enum Kind: String, Equatable, Sendable {
        case notYetSupported
        case xcodeMissing
        /// The developer directory is not inside an Apple-signed Xcode.
        case xcodeUntrusted
        case devicectlFailed
        /// Xcode could not mount its developer disk image, for a reason other than the lock or Developer Mode.
        case diskImageFailed
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
        case stateNotReached
        case uiAutomationOff
        case certificateNotTrusted
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
        /// The app in front is not the one this command may drive, or that app is deny-listed or outside the allowance.
        case appNotAllowed
        /// `app_not_allowed` only because of what is in front now; it clears when the app under test comes back.
        case otherAppInFront
        /// A system alert or sheet is over the app.
        case systemPromptInFront
        /// The same on a test device, where an agent may answer it, so no person is asked.
        case systemPromptOnTestDevice
        /// A physical iPhone or iPad needs a pinned app and none was named.
        case appRequired
        /// The device's allowance lapsed while a session broker ran (expired, removed or its seal broken).
        case notAllowed
        /// An Offsider environment variable holds a value it cannot use.
        case invalidSetting
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
            "\(feature) on a physical iPhone or iPad is not available in this version of Offsider, and \(udid) is one. Use an iOS simulator from `offsider devices`."
        )
    }

    static func xcodeMissing(_ detail: String) -> IOSDeviceError {
        IOSDeviceError(.xcodeMissing, XcodeSuggestion.current.adding(to: "No usable Xcode is selected: \(detail)."), hint: XcodeSuggestion.current.select)
    }

    /// `cause` is devicectl's own error: what it names beats its first line, which only says what it was trying.
    static func devicectlFailed(_ command: String, udid: String?, detail: String, cause: CoreDeviceErrorInfo? = nil) -> IOSDeviceError {
        if let udid, let cause {
            if cause.isLocked {
                return IOSDeviceError(.locked, "\(udid) is locked, so Xcode could not reach it. Unlock it, then retry; Offsider never types a passcode.")
            }
            if cause.isDeveloperModeOff { return developerModeOff(udid) }
            if cause.isDiskImageMountFailure {
                return IOSDeviceError(
                    .diskImageFailed,
                    "Xcode could not mount its developer disk image on \(udid): \(TerminalText.line(cause.rootCause, cap: 200)). Keep it connected and unlocked, then retry; if it fails again, update Xcode."
                )
            }
        }
        let reason = detail.isEmpty ? "" : ": \(detail)"
        let next = udid.map { "Run `offsider doctor --device \($0)` to check the device." } ?? "Run `offsider doctor` to check Xcode."
        return IOSDeviceError(.devicectlFailed, "`devicectl \(command)` failed\(reason). \(next)")
    }

    static func notListed(_ udid: String) -> IOSDeviceError {
        IOSDeviceError(
            .notListed,
            "No iPhone or iPad with UDID \(udid) is known to this Mac. Connect it with a cable, unlock it and trust this Mac, then run `offsider devices`."
        )
    }

    static func unavailable(_ name: String) -> IOSDeviceError {
        IOSDeviceError(.unavailable, "\(name) is paired with this Mac but not connected. Connect its cable and unlock it, then run `offsider devices`.")
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
            return IOSDeviceError(.unavailable, "\(udid) is not attached over USB. Connect its cable and unlock it, then run `offsider devices`.")
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

    /// iOS refuses a developer's apps until a person trusts the certificate on the device.
    static func runnerCertificateNotTrusted(_ name: String) -> IOSDeviceError {
        IOSDeviceError(.certificateNotTrusted, "\(name) does not trust the certificate that signs the Offsider runner. On it, go to Settings > General > VPN & Device Management and trust the certificate, then retry.")
    }

    /// A failure on the stream to the device runner, after usbmuxd connected it; nothing was sent to the app.
    public static func runner(_ error: UsbmuxError, udid: String) -> IOSDeviceError {
        switch error {
        case .timedOut:
            let answer = ErrorAudience.current == .person ? "answer it on the device" : "ask the user to answer it on the device"
            return IOSDeviceError(.runnerUnavailable, "The runner on \(udid) did not answer in time, so no input was sent. If the device shows a system prompt, \(answer). Otherwise retry; if it persists, run `offsider doctor --device \(udid)`.")
        case .socketUnavailable, .notOnUSB, .notAttached, .result:
            return usbmux(error, udid: udid)
        case .closed, .malformed:
            return IOSDeviceError(.runnerUnavailable, "The runner on \(udid) closed the connection or sent a reply Offsider could not read, so no input was sent. Retry; if it persists, run `offsider doctor --device \(udid)`.")
        }
    }

    /// A system alert or sheet the app may be waiting on, which stalls every read of it. `title` comes from the device and can hold an app's name, so it is cleaned and capped, and loses backticks, which mark the hint.
    static func systemPromptInFront(_ title: String, udid: String, testDevice: Bool = false) -> IOSDeviceError {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "`", with: "'")
        let prompt = trimmed.isEmpty ? "A system prompt" : "The system prompt \(TerminalText.quoted(SelectorText.truncated(trimmed, limit: 120)))"
        let stopped = "\(prompt) is in front on \(udid), so Offsider did not read or touch the app."
        if testDevice {
            return IOSDeviceError(.systemPromptOnTestDevice, "\(stopped) Read it with `offsider describe-ui --summary --device \(udid)`, then answer it with `offsider tap --label <button> --device \(udid)`.")
        }
        let answer = ErrorAudience.current == .person ? "Answer it on the device" : "Ask the user to answer it on the device"
        return IOSDeviceError(.systemPromptInFront, "\(stopped) \(answer), then retry.")
    }

    /// A prompt that rose just after a read began holds that read; the next one gets through as it ends, within seconds, and is not held.
    static func runnerTimedOutOnTestDevice(_ udid: String) -> IOSDeviceError {
        IOSDeviceError(.runnerUnavailable, "The runner on \(udid) did not answer in time, so nothing was read or sent. A system prompt may be holding the app: `offsider describe-ui --summary --device \(udid)` reads what is in front.")
    }

    static func runnerNotListening(_ udid: String) -> IOSDeviceError {
        IOSDeviceError(.runnerUnavailable, "Nothing on \(udid) accepted the runner connection, so no input was sent. Retry; if it persists, run `offsider doctor --device \(udid)`.")
    }
}

/// Another app in front clears when the app under test comes back, so a wait counts it as not yet met.
extension IOSDeviceError: OtherAppFailure {
    public var isOtherAppInFront: Bool { kind == .otherAppInFront || kind == .systemPromptInFront }
}

extension IOSDeviceError: OffsiderFailure {
    public var reason: FailureReason {
        switch kind {
        case .notYetSupported: return .notSupported
        case .xcodeMissing: return .xcodeMissing
        case .xcodeUntrusted: return .xcodeUnusable
        case .devicectlFailed, .diskImageFailed: return .commandFailed
        case .notListed, .unavailable: return .deviceNotFound
        case .notWired: return .deviceNotWired
        case .untrusted: return .deviceUntrusted
        case .developerModeOff: return .developerModeOff
        case .preparing: return .devicePreparing
        case .usbmuxUnavailable: return .usbmuxUnavailable
        case .usbmuxFailed: return .commandFailed
        case .runnerUnavailable: return .runnerUnavailable
        case .locked: return .deviceLocked
        case .stateNotReached: return .stateNotReached
        case .uiAutomationOff: return .uiAutomationOff
        case .systemPromptInFront, .systemPromptOnTestDevice: return .systemPromptInFront
        case .certificateNotTrusted: return .certificateNotTrusted
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
        case .appNotAllowed, .otherAppInFront: return .appNotAllowed
        case .notAllowed: return .deviceNotAllowed
        case .appRequired, .invalidSetting: return .usage
        }
    }

    public var failureMessage: String { message }

    public var ask: String? { kind == .systemPromptOnTestDevice ? nil : reason.personAsk }

    /// The message's first backticked Offsider or xcode-select command.
    public var hint: String? {
        if let explicitHint { return explicitHint }
        let quoted = message.split(separator: "`", omittingEmptySubsequences: false).enumerated().filter { $0.offset % 2 == 1 }
        return quoted.map { String($0.element) }.first { $0.hasPrefix("offsider ") || $0.hasPrefix("xcode-select ") || $0.hasPrefix("sudo xcode-select ") }
    }
}
