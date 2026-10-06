import Foundation
import OffsiderCore

/// Every Android failure a user can see; each message says what happened and what to do next.
public struct AndroidError: LocalizedError, CustomStringConvertible, Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case sdkVariableWithoutAdb
        case nonLoopbackAdbServer
        case invalidAdbServerSetting
        case adbServerNotRunning
        case adbServerStartFailed
        case adbServerNoAnswer
        case adbProtocol
        case adbCommandFailed
        case serialNotRunning
        case deviceOffline
        case deviceUnauthorised
        case stillBooting
        case deviceLocked
        case avdNotRunning
        case noDeviceNamed
        case avdRunningTwice
        case ambiguousDeviceName
        case unsupportedDevice
        case appNotInstalled
        case grpcRequired
        case uiautomatorBusy
        case uiautomatorIdle
        case uiautomatorNoWindow
        case uiautomatorFailed
        case helperUnavailable
        case helperBusy
        case helperCrashed
        case helperTimedOut
        case helperFailed
        case noWindow
        case noFocusedField
        case fieldNotEditable
        case securePasteRefused
        case textNotAccepted
        case unsupportedKey
        case unsupportedButton
        case unsupportedControlCharacter
        case displayProbeUnparseable
        case displaysUnreadable
        case unknownDisplay
        case displayOff
        case postureUnavailable
        case postureFailed
        case notSupported
        case inputFailed
        case invalidSetting
        case grpcNoCredentials
        case grpcKeyNotActivated
        case grpcUnauthenticated
        case grpcPermissionDenied
        case grpcUnavailable
        case grpcDeadlineExceeded
        case grpcFailed
        case screenshotFailed
        case videoOutputFailed
        case noAVDNamed
        case emulatorMissing
        case emulatorLaunchFailed
        case emulatorExited
        case bootTimeout
    }

    public let kind: Kind
    public let message: String

    public init(_ kind: Kind, _ message: String) {
        self.kind = kind
        self.message = message
    }

    public var errorDescription: String? { message }
    public var description: String { message }

    static func sdkVariableWithoutAdb(variable: String, path: String) -> AndroidError {
        AndroidError(
            .sdkVariableWithoutAdb,
            "\(variable) is \(path), which has no platform-tools/adb. Install Android SDK Platform-Tools there, or unset \(variable)."
        )
    }

    static func nonLoopbackAdbServer(variable: String, value: String) -> AndroidError {
        AndroidError(
            .nonLoopbackAdbServer,
            "\(variable) is \(value), which is not on this Mac. Offsider only talks to an adb server on 127.0.0.1, ::1 or a Unix socket. Unset it or point it at a local server."
        )
    }

    static func invalidAdbServerSetting(variable: String, value: String) -> AndroidError {
        let expected = variable == "ADB_SERVER_SOCKET"
            ? "tcp:<port>, tcp:127.0.0.1:<port>, tcp:[::1]:<port> or localfilesystem:<path>"
            : "a port from 1 to 65535"
        return AndroidError(
            .invalidAdbServerSetting,
            "\(variable) is \(value), which Offsider cannot read. Use \(expected), or unset it."
        )
    }

    static func adbServerNotRunning(endpoint: String) -> AndroidError {
        AndroidError(.adbServerNotRunning, "No adb server is running on \(endpoint). Start it with `adb start-server`, then retry.")
    }

    static func adbServerStartFailed(adb: String, status: Int32, detail: String) -> AndroidError {
        let reason = detail.isEmpty ? "" : " (\(detail))"
        return AndroidError(
            .adbServerStartFailed,
            "Could not start the adb server: `\(adb) start-server` exited \(status)\(reason). Run `adb start-server` to see why."
        )
    }

    static func adbServerNoAnswer(endpoint: String, seconds: Int) -> AndroidError {
        AndroidError(
            .adbServerNoAnswer,
            "The adb server on \(endpoint) did not answer within \(seconds) s. Restart it with `adb kill-server && adb start-server`."
        )
    }

    static func adbProtocol(_ detail: String) -> AndroidError {
        AndroidError(
            .adbProtocol,
            "The adb server sent a reply Offsider could not read (\(detail)). Restart it with `adb kill-server && adb start-server`."
        )
    }

    static func adbCommandFailed(serial: String, command: String, detail: String) -> AndroidError {
        let reason = detail.isEmpty ? "" : ": \(detail)"
        return AndroidError(.adbCommandFailed, "`\(command)` failed on \(serial)\(reason).")
    }

    static func serialNotRunning(_ serial: String) -> AndroidError {
        AndroidError(
            .serialNotRunning,
            "No emulator with serial \(serial) is running. Run `offsider list-devices` to see running emulators."
        )
    }

    static func phoneNotConnected(_ serial: String) -> AndroidError {
        AndroidError(
            .serialNotRunning,
            "No device with serial \(serial) is connected. Check the cable, then run `offsider list-devices` to see connected devices."
        )
    }

    static func phoneOffline(_ serial: String) -> AndroidError {
        AndroidError(.deviceOffline, "Phone \(serial) is offline in adb. Reconnect the cable and unlock the phone, then retry.")
    }

    static func phoneUnauthorised(_ serial: String) -> AndroidError {
        AndroidError(
            .deviceUnauthorised,
            "Phone \(serial) is not authorised for adb. Unlock it and accept the \"Allow USB debugging?\" prompt, then retry."
        )
    }

    public static func networkDevice(_ serial: String) -> AndroidError {
        AndroidError(
            .unsupportedDevice,
            "Offsider drives Android phones over USB only, and \(serial) is a network adb connection. Connect the phone with a cable and use its USB serial from `offsider list-devices`; for an emulator, use its emulator-NNNN serial."
        )
    }

    static func bootPhone(_ serial: String) -> AndroidError {
        AndroidError(.unsupportedDevice, "boot starts emulators, and \(serial) is a connected phone. Run `offsider list-devices` to see AVD names.")
    }

    static func ambiguousDeviceName(_ name: String, emulatorSerial: String) -> AndroidError {
        AndroidError(
            .ambiguousDeviceName,
            "\(name) names both a connected phone and a running AVD. Pass the emulator serial (\(emulatorSerial)) for the AVD; to drive the phone, rename the AVD or stop the emulator."
        )
    }

    static func appNotInstalled(_ package: String, serial: String) -> AndroidError {
        AndroidError(
            .appNotInstalled,
            "\(package) is not installed on \(serial). Install it with `adb -s \(serial) install <path-to-apk>`, or check the package name with adb -s \(serial) shell pm list packages."
        )
    }

    /// `feature` works only on emulators; the advice is the alternative, never `offsider boot`.
    static func emulatorOnly(_ feature: String, serial: String, model: String?, alternative: String) -> AndroidError {
        let name = model.map { " (\($0))" } ?? ""
        return AndroidError(.unsupportedDevice, "\(feature) on Android needs an emulator, and \(serial) is a physical device\(name). \(alternative)")
    }

    static func deviceOffline(_ serial: String, avd: String?) -> AndroidError {
        AndroidError(
            .deviceOffline,
            "Emulator \(serial) is offline in adb. Wait a few seconds and retry, or restart it with `offsider boot \(avd ?? "<AVD>")`."
        )
    }

    static func deviceUnauthorised(_ serial: String, avd: String?) -> AndroidError {
        AndroidError(
            .deviceUnauthorised,
            "Emulator \(serial) is not authorised for adb. Accept the prompt on the emulator, or restart it with `offsider boot \(avd ?? "<AVD>")`."
        )
    }

    static func stillBooting(_ serial: String, avd: String?) -> AndroidError {
        let name = avd.map { " (\($0))" } ?? ""
        return AndroidError(
            .stillBooting,
            "Emulator \(serial)\(name) is still booting. Wait for it, or run `offsider boot \(avd ?? "<AVD>")`, which waits until it is ready."
        )
    }

    static func avdNotRunning(_ name: String) -> AndroidError {
        AndroidError(.avdNotRunning, "Emulator \(name) is not running. Start it with `offsider boot \(name)`.")
    }

    static func noDeviceNamed(_ name: String) -> AndroidError {
        AndroidError(.noDeviceNamed, "No device named \(name). Run `offsider list-devices` to find device IDs.")
    }

    static func avdRunningTwice(_ name: String, serials: [String]) -> AndroidError {
        AndroidError(
            .avdRunningTwice,
            "\(name) is running more than once (\(serials.joined(separator: ", "))). Pass one serial with --device."
        )
    }

    static func invalidSetting(variable: String, value: String, expected: String) -> AndroidError {
        AndroidError(.invalidSetting, "\(variable) is \(value), which Offsider cannot read. Use \(expected), or unset it.")
    }

    static func grpcNoCredentials(port: Int, avd: String?, missing: String) -> AndroidError {
        AndroidError(
            .grpcNoCredentials,
            "The emulator's gRPC endpoint on port \(port) offers no credentials Offsider can use (its discovery file has no \(missing)). Restart it with `offsider boot \(avd ?? "<AVD>")`."
        )
    }

    static func grpcKeyNotActivated(activeListPath: String, avd: String?) -> AndroidError {
        AndroidError(
            .grpcKeyNotActivated,
            "The emulator did not accept Offsider's signing key within 3 s (`\(activeListPath)`). Restart it with `offsider boot \(avd ?? "<AVD>")`."
        )
    }

    static func grpcKeyNotWritten(directory: String, detail: String) -> AndroidError {
        AndroidError(
            .grpcKeyNotActivated,
            "Could not give the emulator Offsider's signing key in \(directory) (\(detail)). Check that the folder is writable, or restart the emulator."
        )
    }

    static func grpcUnauthenticated(endpoint: String, method: String, avd: String?) -> AndroidError {
        AndroidError(
            .grpcUnauthenticated,
            "The emulator's gRPC endpoint (\(endpoint)) rejected Offsider's credentials for `\(method)`. Restart the emulator with `offsider boot \(avd ?? "<AVD>")` so it issues fresh credentials."
        )
    }

    static func grpcPermissionDenied(allowlist: String, issuer: String, method: String, avd: String?) -> AndroidError {
        AndroidError(
            .grpcPermissionDenied,
            "The emulator's gRPC allowlist (`\(allowlist)`) does not let issuer \(issuer) call `\(method)`. Restart the emulator with `offsider boot \(avd ?? "<AVD>")` so it offers a token."
        )
    }

    static func grpcUnavailable(port: Int) -> AndroidError {
        AndroidError(
            .grpcUnavailable,
            "The emulator's gRPC endpoint on port \(port) did not answer on 127.0.0.1 or [::1]; it may be shutting down."
        )
    }

    static func grpcDeadlineExceeded(method: String, seconds: Int) -> AndroidError {
        AndroidError(
            .grpcDeadlineExceeded,
            "The emulator did not answer `\(method)` within \(seconds) s. It may be overloaded; retry, or check it with `offsider list-devices`."
        )
    }

    static func grpcFailed(endpoint: String, method: String, detail: String) -> AndroidError {
        AndroidError(.grpcFailed, "The emulator's gRPC endpoint (\(endpoint)) failed `\(method)`: \(detail).")
    }

    static func screenshotFailed(_ serial: String, detail: String) -> AndroidError {
        AndroidError(.screenshotFailed, "Could not read the screen of \(serial) (\(detail)). Retry, or check it with `offsider list-devices`.")
    }

    static func videoOutputFailed(detail: String) -> AndroidError {
        AndroidError(.videoOutputFailed, "Could not write video frames to standard output (\(detail)).")
    }

    static func grpcForced(serial: String, reason: String) -> AndroidError {
        AndroidError(
            .grpcRequired,
            "OFFSIDER_ANDROID_TRANSPORT is grpc, which needs the emulator's gRPC endpoint, and \(serial) \(reason). Unset it to fall back to adb."
        )
    }

    static func grpcRequiredForText(serial: String, avd: String?, reason: AdbReason) -> AndroidError {
        if reason == .physicalDevice {
            return emulatorOnly(
                "Typing non-ASCII text key by key",
                serial: serial,
                model: nil,
                alternative: "Use `offsider type --replace <full text> --device \(serial)`, which sets the field through the helper."
            )
        }
        return grpcRequired(feature: "Typing non-ASCII text", serial: serial, avd: avd, reason: reason, alternative: "type ASCII only")
    }

    /// `feature` needs gRPC and this command is on adb; the advice follows from why.
    static func grpcRequired(feature: String, serial: String, avd: String?, reason: AdbReason, alternative: String) -> AndroidError {
        let prefix = "\(feature) on Android needs the emulator's gRPC endpoint, and"
        if reason == .physicalDevice {
            let advice = alternative.prefix(1).uppercased() + alternative.dropFirst()
            return emulatorOnly(feature, serial: serial, model: nil, alternative: "\(advice).")
        }
        if reason == .forced {
            return AndroidError(.grpcRequired, "\(prefix) OFFSIDER_ANDROID_TRANSPORT is adb. Unset it, or \(alternative).")
        }
        return AndroidError(
            .grpcRequired,
            "\(prefix) \(serial) \(reason.clause). Restart it with `offsider boot \(avd ?? "<AVD>")`, or \(alternative)."
        )
    }

    static func uiautomatorBusy(_ serial: String) -> AndroidError {
        AndroidError(
            .uiautomatorBusy,
            "uiautomator returned no screen hierarchy on \(serial). Another UiAutomation client (Appium, Maestro, uiautomator, an instrumentation test or Layout Inspector) may be connected: stop it and retry. `adb -s \(serial) logcat -d` shows the cause."
        )
    }

    static func uiautomatorIdle(_ serial: String) -> AndroidError {
        AndroidError(
            .uiautomatorIdle,
            "The screen on \(serial) did not settle within uiautomator's idle wait (an animation may be running). Retry when the screen is still."
        )
    }

    static func uiautomatorNoWindow(_ serial: String) -> AndroidError {
        AndroidError(.uiautomatorNoWindow, "uiautomator found no window on \(serial). Unlock the emulator and bring an app to the front.")
    }

    static func uiautomatorFailed(_ serial: String, detail: String) -> AndroidError {
        AndroidError(.uiautomatorFailed, "uiautomator could not read the screen on \(serial) (\(detail)). Retry, or run `adb -s \(serial) shell uiautomator dump` to see why.")
    }

    static func helperUnavailableForced(_ serial: String, reason: HelperUnavailableReason) -> AndroidError {
        AndroidError(
            .helperUnavailable,
            "The UiAutomation helper is unavailable on \(serial) (\(reason)), and OFFSIDER_ANDROID_TREE is helper. Unset it to fall back to uiautomator."
        )
    }

    static func helperUnavailableForInput(_ serial: String, reason: HelperUnavailableReason) -> AndroidError {
        AndroidError(
            .helperUnavailable,
            "The UiAutomation helper is unavailable on \(serial) (\(reason)), and OFFSIDER_ANDROID_INPUT is helper. Unset it to send input with `input` instead."
        )
    }

    static func sliderNeedsHelper(_ serial: String, reason: HelperUnavailableReason) -> AndroidError {
        guard reason != .forcedOff else {
            return AndroidError(
                .helperUnavailable,
                "slider on Android reads slider values through the UiAutomation helper, and OFFSIDER_ANDROID_TREE is uiautomator. Unset it, then retry."
            )
        }
        return AndroidError(
            .helperUnavailable,
            "slider on Android reads slider values through the UiAutomation helper, which is unavailable on \(serial) (\(reason))."
        )
    }

    static func helperBusy(_ serial: String) -> AndroidError {
        AndroidError(
            .helperBusy,
            "Another UiAutomation client is connected to \(serial) (Appium, Maestro, uiautomator, an instrumentation test or Layout Inspector), so Offsider cannot read its screen. Stop that client, then retry."
        )
    }

    static func helperBusy(_ serial: String, stalePid pid: Int32) -> AndroidError {
        AndroidError(
            .helperBusy,
            "An earlier Offsider helper (pid \(pid)) still holds UiAutomation on \(serial). It exits within 10 s of losing its command; to free it now, run `adb -s \(serial) shell kill \(pid)`."
        )
    }

    static func helperCrashed(_ serial: String, detail: String) -> AndroidError {
        AndroidError(
            .helperCrashed,
            "The UiAutomation helper on \(serial) stopped unexpectedly (\(detail)). Retry; `adb -s \(serial) logcat -d -s OffsiderHelper AndroidRuntime` shows why."
        )
    }

    static func helperLostInput(_ serial: String, detail: String) -> AndroidError {
        AndroidError(
            .helperCrashed,
            "The UiAutomation helper on \(serial) stopped while sending input (\(detail)). The input may have reached the device, so Offsider did not send it again; check the screen with `offsider describe-ui --device \(serial)` before retrying."
        )
    }

    static func helperTimedOut(_ serial: String, op: String, seconds: Int) -> AndroidError {
        AndroidError(
            .helperTimedOut,
            "The UiAutomation helper on \(serial) did not answer `\(op)` within \(seconds) s. The emulator may be overloaded; retry when it responds."
        )
    }

    static func helperFailed(_ serial: String, message: String) -> AndroidError {
        AndroidError(
            .helperFailed,
            "The UiAutomation helper could not read the screen of \(serial) (\(message)). Retry, or set OFFSIDER_ANDROID_TREE=uiautomator to read it another way."
        )
    }

    static func noWindow(_ serial: String) -> AndroidError {
        AndroidError(.noWindow, "Offsider found no window on \(serial). Unlock the emulator and bring an app to the front.")
    }

    static func noFocusedField(_ serial: String) -> AndroidError {
        AndroidError(
            .noFocusedField,
            "type --replace needs a focused text field on \(serial), and nothing has input focus. Tap the field first, for example `offsider tap --id <field> --device \(serial)`."
        )
    }

    static func securePasteRefused(_ serial: String) -> AndroidError {
        AndroidError(
            .securePasteRefused,
            "Typing this text into the focused password field on \(serial) would paste it through the emulator's clipboard, so Offsider refused. Use `offsider type --replace <full text> --device \(serial)`, which sets the field without the clipboard."
        )
    }

    static func textNotAccepted(_ serial: String, field: AndroidFieldInfo?, pasted: Bool) -> AndroidError {
        let element = field.map { " (\($0.description))" } ?? ""
        let tried = pasted ? "Ctrl+A, Delete, typed keys and a paste" : "Ctrl+A, Delete and typed keys"
        return AndroidError(
            .textNotAccepted,
            "The focused field on \(serial)\(element) holds less than the text after \(tried): the app filters what it accepts. Check it with describe-ui, and type what the field allows."
        )
    }

    static func fieldNotEditable(_ serial: String, className: String?, resourceId: String?) -> AndroidError {
        let parts = [className.map { "`\($0)`" }, resourceId.map { "id `\($0)`" }].compactMap { $0 }
        let element = parts.isEmpty ? "" : " (\(parts.joined(separator: ", ")))"
        return AndroidError(
            .fieldNotEditable,
            "The element with input focus on \(serial)\(element) is not a text field, so type --replace cannot set its text. Tap the text field first."
        )
    }

    static func unsupportedKey(_ usage: UInt32) -> AndroidError {
        AndroidError(
            .unsupportedKey,
            "Key \(usage) has no Android equivalent. Supported HID usages: 4 to 49, 51 to 57, 58 to 69 (F1 to F12), 73 to 82, 127 to 129 and 224 to 231."
        )
    }

    static func unsupportedControlCharacter(_ scalar: Unicode.Scalar) -> AndroidError {
        let hex = String(scalar.value, radix: 16, uppercase: true)
        let code = String(repeating: "0", count: max(0, 4 - hex.count)) + hex
        return AndroidError(
            .unsupportedControlCharacter,
            "Cannot type the control character U+\(code) on Android. Use `key` for special keys."
        )
    }

    static func displayProbeUnparseable(_ serial: String, firstLine: String) -> AndroidError {
        AndroidError(
            .displayProbeUnparseable,
            "Could not read the display size and rotation of \(serial) (\(firstLine)). Check it with `adb -s \(serial) shell dumpsys input`."
        )
    }

    static func displaysUnreadable(_ serial: String) -> AndroidError {
        AndroidError(
            .displaysUnreadable,
            "Could not find a built-in display in `dumpsys display` on \(serial). Check it with `adb -s \(serial) shell dumpsys display`."
        )
    }

    static func unknownDisplay(_ serial: String, requested: String, available: [DisplayDescriptor]) -> AndroidError {
        let names = available.map { "\($0.role.rawValue) (\($0.platformId))" }.joined(separator: ", ")
        return AndroidError(.unknownDisplay, "Unknown display '\(requested)' on \(serial). Use one of: \(names).")
    }

    static func awakeStateUnreadable(_ serial: String, output: String) -> AndroidError {
        let firstLine = output.split(whereSeparator: \.isNewline).first.map(String.init) ?? "no output"
        return AndroidError.adbCommandFailed(
            serial: serial,
            command: "dumpsys power; dumpsys window policy",
            detail: "expected mWakefulness and the keyguard state but got \(firstLine)"
        )
    }

    static func codeFieldMissing(_ serial: String) -> AndroidError {
        AndroidError(.deviceLocked, "The lock screen of \(serial) showed no PIN or password field, so Offsider typed nothing. Unlock it on the device.")
    }

    static func displayOff(_ serial: String, display: DisplayDescriptor, posture: Posture?) -> AndroidError {
        let state = "The \(display.role.rawValue) display (\(display.platformId)) of \(serial) is off (posture \(posture?.rawValue ?? "unknown")), so it has nothing to capture."
        switch display.role {
        case .cover: return AndroidError(.displayOff, "\(state) Fold the emulator with `offsider posture closed --device \(serial)`, then retry.")
        case .inner: return AndroidError(.displayOff, "\(state) Unfold the emulator with `offsider posture open --device \(serial)`, then retry.")
        case .main, .external: return AndroidError(.displayOff, "\(state) Turn it on, then retry.")
        }
    }

    static func notFoldable(_ serial: String) -> AndroidError {
        AndroidError(.postureUnavailable, "\(serial) is not a foldable device; `cmd device_state print-states` lists fewer than two states.")
    }

    static func postureUnavailable(_ serial: String, posture: Posture, states: [String], reason: AdbReason) -> AndroidError {
        AndroidError(
            .postureUnavailable,
            "Cannot set \(serial) to \(posture.rawValue): its gRPC endpoint \(reason.clause), and `cmd device_state print-states` lists no matching state (\(states.joined(separator: ", "))). Fold it in the emulator's extended controls instead."
        )
    }

    static func postureFailed(_ serial: String, path: String, detail: String) -> AndroidError {
        let trimmed = detail.hasSuffix(".") ? String(detail.dropLast()) : detail
        return AndroidError(.postureFailed, "Setting the posture of \(serial) over \(path) failed: \(trimmed). Check with `offsider posture --device \(serial)`.")
    }

    static func noAVDNamed(_ name: String, available: [String]) -> AndroidError {
        let list = available.isEmpty ? "This Mac has no AVDs." : "AVDs on this Mac: \(available.joined(separator: ", "))."
        return AndroidError(.noAVDNamed, "No AVD named \(name). \(list) Create one in Android Studio's Device Manager.")
    }

    static func emulatorMissing(sdkRoot: String) -> AndroidError {
        AndroidError(.emulatorMissing, "The Android Emulator is not installed in \(sdkRoot)/emulator. Install it with Android Studio's SDK Manager.")
    }

    static func emulatorLaunchFailed(path: String, detail: String) -> AndroidError {
        AndroidError(.emulatorLaunchFailed, "Could not start \(path): \(detail).")
    }

    /// Names the stale lock files boot removed before this launch, which the failure may be about.
    func namingStaleLocks(_ names: [String], in directory: String) -> AndroidError {
        guard !names.isEmpty else { return self }
        return AndroidError(kind, message + " Before this launch Offsider removed \(names.joined(separator: " and ")) from \(directory), left by an emulator that was no longer running.")
    }

    static func emulatorExited(status: Int32, logPath: String, tail: String) -> AndroidError {
        let lines = tail.isEmpty ? " The log is empty." : " Last lines of \(logPath):\n\(tail)"
        return AndroidError(.emulatorExited, "The emulator exited during start-up (status \(status)).\(lines)")
    }

    static func bootTimeout(avd: String, serial: String?, seconds: Int, logPath: String?) -> AndroidError {
        let device = serial.map { "\(avd) (\($0))" } ?? avd
        let hint = logPath.map { "check its window or \($0)" } ?? "check its window"
        return AndroidError(
            .bootTimeout,
            "\(device) did not finish booting within \(seconds) s. It is still running; \(hint), then run `offsider boot \(avd)` again to keep waiting."
        )
    }

    static func notSupported(_ feature: String) -> AndroidError {
        AndroidError(.notSupported, "\(feature) is not supported on Android emulators in this build.")
    }

    /// `input` has no multi-finger form, so two fingers need gRPC or the helper.
    static let twoFingersOverInput = AndroidError(
        .notSupported,
        "Two-finger touches cannot go through `input`, which moves one finger. Use an emulator's gRPC input (leave OFFSIDER_ANDROID_TRANSPORT unset), or set OFFSIDER_ANDROID_INPUT=helper to send them through the UiAutomation helper."
    )

    static func unsupportedButton(_ button: HardwareButton) -> AndroidError {
        AndroidError(.unsupportedButton, "The \(Self.buttonName(button)) button is iOS only. Android buttons: back, app-switch, home, lock, volume-up, volume-down.")
    }

    static func inputFailed(serial: String, detail: String) -> AndroidError {
        AndroidError(.inputFailed, "Input on \(serial) failed: \(detail). Check that the device is still connected with `offsider list-devices`.")
    }

    private static func buttonName(_ button: HardwareButton) -> String {
        switch button {
        case .applePay: return "apple-pay"
        case .sideButton: return "side-button"
        case .appSwitch: return "app-switch"
        case .volumeUp: return "volume-up"
        case .volumeDown: return "volume-down"
        default: return button.rawValue
        }
    }
}

/// Android shows no window for a moment while an activity starts or restarts; polling callers retry it.
extension AndroidError: TransientFailure {
    public var isTransient: Bool { kind == .uiautomatorNoWindow || kind == .noWindow }
}

extension AndroidError: OffsiderFailure {
    public var reason: FailureReason {
        switch kind {
        case .sdkVariableWithoutAdb: return .androidSdkMissing
        case .nonLoopbackAdbServer, .invalidAdbServerSetting: return .adbServerMisconfigured
        case .adbServerNotRunning, .adbServerStartFailed, .adbServerNoAnswer: return .adbServerUnavailable
        case .adbProtocol: return .adbProtocolError
        case .adbCommandFailed: return .adbCommandFailed
        case .serialNotRunning, .noDeviceNamed: return .deviceNotFound
        case .avdNotRunning: return .deviceNotBooted
        case .deviceOffline, .stillBooting: return .deviceNotReady
        case .deviceUnauthorised: return .deviceUnauthorised
        case .deviceLocked: return .deviceLocked
        case .avdRunningTwice, .ambiguousDeviceName: return .deviceAmbiguous
        case .unsupportedDevice: return .notSupported
        case .appNotInstalled: return .appNotInstalled
        case .noAVDNamed: return .avdNotFound
        case .grpcRequired: return .emulatorGrpcRequired
        case .uiautomatorBusy, .helperBusy: return .uiautomationBusy
        case .uiautomatorIdle: return .screenNotIdle
        case .uiautomatorNoWindow, .noWindow: return .noWindow
        case .uiautomatorFailed: return .treeReadFailed
        case .helperUnavailable: return .helperUnavailable
        case .helperCrashed, .helperFailed: return .helperFailed
        case .helperTimedOut: return .helperTimedOut
        case .noFocusedField: return .noFocusedField
        case .fieldNotEditable: return .fieldNotEditable
        case .securePasteRefused: return .securePasteRefused
        case .textNotAccepted: return .textNotAccepted
        case .unsupportedKey: return .unsupportedKey
        case .unsupportedButton: return .unsupportedButton
        case .unsupportedControlCharacter: return .unsupportedText
        case .displayProbeUnparseable, .displaysUnreadable: return .displayUnreadable
        case .unknownDisplay: return .unknownDisplay
        case .displayOff: return .displayOff
        case .postureUnavailable, .notSupported: return .notSupported
        case .postureFailed: return .postureFailed
        case .inputFailed: return .inputFailed
        case .invalidSetting: return .invalidSetting
        case .grpcNoCredentials, .grpcKeyNotActivated, .grpcUnauthenticated, .grpcPermissionDenied: return .emulatorGrpcAuthFailed
        case .grpcUnavailable: return .emulatorGrpcUnavailable
        case .grpcDeadlineExceeded: return .emulatorTimedOut
        case .grpcFailed: return .emulatorGrpcFailed
        case .screenshotFailed: return .screenshotFailed
        case .videoOutputFailed: return .videoFailed
        case .emulatorMissing: return .emulatorMissing
        case .emulatorLaunchFailed, .emulatorExited: return .emulatorLaunchFailed
        case .bootTimeout: return .bootTimedOut
        }
    }

    public var failureMessage: String { message }

    /// The message's first backticked Offsider or adb command; never the failed command itself, which can carry typed text.
    public var hint: String? {
        switch reason.exitCode {
        case .deviceUnavailable where kind == .deviceLocked:
            return Self.firstCommand(in: message)
        case .deviceUnavailable where kind == .avdNotRunning || kind == .stillBooting || kind == .deviceOffline:
            return Self.firstCommand(in: message) ?? "offsider list-devices"
        case .deviceUnavailable:
            return "offsider list-devices"
        default:
            return kind == .adbCommandFailed ? nil : Self.firstCommand(in: message)
        }
    }

    private static func firstCommand(in message: String) -> String? {
        let parts = message.split(separator: "`", omittingEmptySubsequences: false)
        guard parts.count >= 3 else { return nil }
        let command = String(parts[1])
        return command.hasPrefix("offsider ") || command.hasPrefix("adb ") ? command : nil
    }
}

extension HelperDexError: OffsiderFailure {
    public var reason: FailureReason { .helperUnavailable }
    public var failureMessage: String { description }
}
