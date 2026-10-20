import Foundation

/// The environment a child process Offsider starts may see: an allow-list per kind of child, never the whole caller environment.
public enum ChildEnvironment {
    public enum Profile: Sendable {
        case base
        /// A short-lived Apple tool such as `xcrun simctl`, `devicectl` or `open`: the basics and Xcode's location.
        case appleTool
        /// The Android Emulator: SDK and AVD locations, adb's port, mDNS and crash reporting off.
        case androidEmulator
        /// `adb start-server`: SDK and key locations, the server's socket and USB backend, mDNS off.
        case adbServer
        /// `offsider` started detached as a broker: Xcode's location and Offsider's own settings.
        case offsiderBroker
        /// `offsider` started detached as an Android device's broker: the SDK, the adb server's address, Offsider's settings, mDNS off.
        case androidBroker
        /// `xcodebuild`: Xcode's location, the runner's `TEST_RUNNER_*` settings and a proxy for provisioning.
        case xcodebuild
    }

    static let baseNames: Set<String> = ["HOME", "PATH", "TMPDIR", "USER", "LOGNAME", "SHELL", "LANG", "__CF_USER_TEXT_ENCODING"]

    static let androidSDKNames: Set<String> = [
        "ANDROID_HOME", "ANDROID_SDK_ROOT", "ANDROID_AVD_HOME", "ANDROID_EMULATOR_HOME", "ANDROID_USER_HOME", "ANDROID_PREFS_ROOT",
        "ANDROID_ADB_SERVER_PORT",
    ]

    static let adbServerNames: Set<String> = [
        "ANDROID_HOME", "ANDROID_SDK_ROOT", "ANDROID_USER_HOME", "ANDROID_EMULATOR_HOME", "ANDROID_PREFS_ROOT", "ANDROID_VENDOR_KEYS", "ADB_VENDOR_KEYS",
        "ANDROID_ADB_SERVER_PORT", "ANDROID_ADB_SERVER_ADDRESS", "ADB_SERVER_SOCKET", "ADB_LIBUSB",
    ]

    static let proxyNames: Set<String> = ["HTTP_PROXY", "HTTPS_PROXY", "NO_PROXY", "http_proxy", "https_proxy", "no_proxy"]

    /// The crash-reporting switch the emulator binary reads (`emulator -help-environment` names none); forced off.
    public static let emulatorCrashReportingVariable = "ANDROID_EMU_ENABLE_CRASH_REPORTING"

    /// The variables of `environment` the profile allows, plus what it forces.
    public static func make(_ profile: Profile, from environment: [String: String]) -> [String: String] {
        var result = environment.filter { allows(profile, $0.key) }
        switch profile {
        case .base, .appleTool, .offsiderBroker, .xcodebuild:
            break
        case .androidEmulator:
            result["ADB_MDNS"] = "0"
            result[emulatorCrashReportingVariable] = "0"
        case .adbServer, .androidBroker:
            result["ADB_MDNS"] = "0"
        }
        return result
    }

    public static func allows(_ profile: Profile, _ name: String) -> Bool {
        if baseNames.contains(name) || name.hasPrefix("LC_") { return true }
        switch profile {
        case .base: return false
        case .appleTool: return name == "DEVELOPER_DIR"
        case .androidEmulator: return androidSDKNames.contains(name)
        case .adbServer: return adbServerNames.contains(name)
        case .offsiderBroker: return name == "DEVELOPER_DIR" || name.hasPrefix("OFFSIDER_")
        case .androidBroker: return adbServerNames.contains(name) || androidSDKNames.contains(name) || name.hasPrefix("OFFSIDER_")
        case .xcodebuild: return name == "DEVELOPER_DIR" || name.hasPrefix("TEST_RUNNER_") || proxyNames.contains(name)
        }
    }
}
