import Foundation

/// Every Android failure a user can see; each message says what happened and what to do next.
public struct AndroidError: LocalizedError, CustomStringConvertible, Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case sdkVariableWithoutAdb
        case nonLoopbackAdbServer
        case invalidAdbServerSetting
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
        case unsupportedControlCharacter
        case displayProbeUnparseable
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

    static func grpcRequiredForText(serial: String, avd: String?, reason: String) -> AndroidError {
        AndroidError(
            .grpcRequired,
            "Typing non-ASCII text on Android needs the emulator's gRPC endpoint, and \(serial) \(reason). Restart it with `offsider boot \(avd ?? "<AVD>")`, or type ASCII only."
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
            "Key \(usage) has no Android equivalent. Supported HID usages: 4 to 57, 58 to 69 (F1 to F12), 73 to 82, 127 to 129 and 224 to 231."
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
}
