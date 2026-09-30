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
        case avdNotRunning
        case noDeviceNamed
        case avdRunningTwice
        case grpcRequired
        case uiautomatorBusy
        case uiautomatorIdle
        case uiautomatorNoWindow
        case uiautomatorFailed
        case unsupportedKey
        case unsupportedButton
        case unsupportedControlCharacter
        case displayProbeUnparseable
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
        grpcRequired(feature: "Typing non-ASCII text", serial: serial, avd: avd, reason: reason, alternative: "type ASCII only")
    }

    /// `feature` needs gRPC and this command is on adb; the advice follows from why.
    static func grpcRequired(feature: String, serial: String, avd: String?, reason: AdbReason, alternative: String) -> AndroidError {
        let prefix = "\(feature) on Android needs the emulator's gRPC endpoint, and"
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

    static func notSupported(_ feature: String) -> AndroidError {
        AndroidError(.notSupported, "\(feature) is not supported on Android emulators in this build.")
    }

    static func unsupportedButton(_ button: HardwareButton) -> AndroidError {
        AndroidError(.unsupportedButton, "The \(Self.buttonName(button)) button is iOS only. Android buttons in this build: home, lock.")
    }

    static func inputFailed(serial: String, detail: String) -> AndroidError {
        AndroidError(.inputFailed, "Input on \(serial) failed: \(detail). Check that the emulator is still running with `offsider list-devices`.")
    }

    private static func buttonName(_ button: HardwareButton) -> String {
        switch button {
        case .applePay: return "apple-pay"
        case .sideButton: return "side-button"
        default: return button.rawValue
        }
    }
}
