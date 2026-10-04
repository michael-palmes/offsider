import OffsiderCore
import Testing
@testable import OffsiderAndroid

@Suite("Android error reasons")
struct AndroidErrorReasonTests {
    static let codes: [(AndroidError.Kind, Int32)] = [
        (.sdkVariableWithoutAdb, 9), (.nonLoopbackAdbServer, 9), (.invalidAdbServerSetting, 9), (.adbServerNotRunning, 9),
        (.adbServerStartFailed, 9), (.adbServerNoAnswer, 9), (.adbProtocol, 1), (.adbCommandFailed, 1),
        (.serialNotRunning, 7), (.deviceOffline, 7), (.deviceUnauthorised, 7), (.stillBooting, 7), (.avdNotRunning, 7),
        (.noDeviceNamed, 7), (.avdRunningTwice, 7), (.ambiguousDeviceName, 7), (.unsupportedDevice, 1), (.appNotInstalled, 1), (.grpcRequired, 9), (.uiautomatorBusy, 8), (.uiautomatorIdle, 1),
        (.uiautomatorNoWindow, 1), (.uiautomatorFailed, 1), (.helperUnavailable, 9), (.helperBusy, 8), (.helperCrashed, 1),
        (.helperTimedOut, 1), (.helperFailed, 1), (.noWindow, 1), (.noFocusedField, 1), (.fieldNotEditable, 1),
        (.securePasteRefused, 1), (.unsupportedKey, 64), (.unsupportedButton, 64), (.unsupportedControlCharacter, 1),
        (.displayProbeUnparseable, 1), (.displaysUnreadable, 1), (.unknownDisplay, 64), (.displayOff, 1),
        (.postureUnavailable, 1), (.postureFailed, 1), (.notSupported, 1), (.inputFailed, 1), (.invalidSetting, 64),
        (.grpcNoCredentials, 1), (.grpcKeyNotActivated, 1), (.grpcUnauthenticated, 1), (.grpcPermissionDenied, 1),
        (.grpcUnavailable, 1), (.grpcDeadlineExceeded, 1), (.grpcFailed, 1), (.screenshotFailed, 1), (.videoOutputFailed, 1),
        (.noAVDNamed, 7), (.emulatorMissing, 9), (.emulatorLaunchFailed, 1), (.emulatorExited, 1), (.bootTimeout, 1),
    ]

    @Test("each Android error kind exits with its documented code")
    func kindsExitWithTheirCodes() {
        for (kind, code) in Self.codes {
            #expect(AndroidError(kind, "x").exitCode.rawValue == code, "\(kind)")
        }
    }

    @Test("a device error hints at the command that fixes it; a failed adb command never echoes itself")
    func hints() {
        #expect(AndroidError.avdNotRunning("Pixel").hint == "offsider boot Pixel")
        #expect(AndroidError.serialNotRunning("emulator-5554").hint == "offsider list-devices")
        #expect(AndroidError.adbServerNotRunning(endpoint: "tcp:5037").hint == "adb start-server")
        #expect(AndroidError.adbCommandFailed(serial: "emulator-5554", command: "shell input text S3NT1NEL", detail: "").hint == nil)
        #expect(AndroidError.appNotInstalled("com.example", serial: "emulator-5554").hint == "adb -s emulator-5554 install <path-to-apk>")
        #expect(AndroidError.ambiguousDeviceName("Pixel", emulatorSerial: "emulator-5554").hint == "offsider list-devices")
        #expect(AndroidError.networkDevice("192.168.1.2:5555").hint == "offsider list-devices")
    }
}
