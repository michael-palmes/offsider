import Foundation

/// Optional capability: marking an Expo dev client's first-launch intro as seen before the app starts.
@MainActor
public protocol ExpoDevClientPreparing: DeviceBackend {
    func prepareExpoDevClient(_ appID: String, on id: DeviceID) async throws
}

public struct ExpoDevClientError: Error, CustomStringConvertible, LocalizedError, Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case invalidAppID
        case notInstalled
        case releaseBuild
        case notDebuggable
        case notDevClient
        case writeFailed
    }

    public let kind: Kind
    public let message: String

    public init(_ kind: Kind, _ message: String) {
        self.kind = kind
        self.message = message
    }

    public var description: String { message }
    public var errorDescription: String? { message }
}

/// expo-dev-menu's preferences: `EXDevMenuIsOnboardingFinished` hides the intro, `EXDevMenuShowsAtLaunch` the menu it opens at launch.
public enum ExpoDevClient {
    public static let iosOnboardingKey = "EXDevMenuIsOnboardingFinished"
    public static let iosShowsAtLaunchKey = "EXDevMenuShowsAtLaunch"
    /// The resource bundle expo-dev-menu ships in a dev client, at the top of the app or inside a framework.
    public static let iosDevMenuBundle = "EXDevMenu.bundle"

    public static let androidPreferencesFile = "shared_prefs/expo.modules.devmenu.sharedpreferences.xml"
    public static let androidOnboardingKey = "isOnboardingFinished"
    public static let androidShowsAtLaunchKey = "showsAtLaunch"

    /// A bundle ID or Android package: dot-separated letters, digits, hyphens (iOS only) and underscores (Android only).
    public static func validate(appID: String) throws -> String {
        let trimmed = appID.trimmingCharacters(in: .whitespaces)
        guard trimmed.range(of: #"^[A-Za-z0-9_-]+(\.[A-Za-z0-9_-]+)+$"#, options: .regularExpression) != nil else {
            throw ExpoDevClientError(.invalidAppID, "'\(appID)' is not a bundle ID or package name such as com.example.app.")
        }
        return trimmed
    }

    // MARK: iOS

    public static func iosAppContainerArguments(udid: String, bundleID: String, container: String) -> [String] {
        ["simctl", "get_app_container", udid, bundleID, container]
    }

    /// Stops a running app, which would otherwise write its old preferences back; simctl fails harmlessly when it is not running.
    public static func iosTerminateArguments(udid: String, bundleID: String) -> [String] {
        ["simctl", "terminate", udid, bundleID]
    }

    /// `defaults` addresses the app's own plist by path, as a simctl spawn of the bundle ID would write the device-wide domain instead.
    public static func iosDefaultsWriteArguments(udid: String, dataContainer: String, bundleID: String) -> [[String]] {
        let domain = iosPreferencesDomain(dataContainer: dataContainer, bundleID: bundleID)
        return [
            ["simctl", "spawn", udid, "defaults", "write", domain, iosOnboardingKey, "-bool", "YES"],
            ["simctl", "spawn", udid, "defaults", "write", domain, iosShowsAtLaunchKey, "-bool", "NO"],
        ]
    }

    public static func iosDefaultsReadArguments(udid: String, dataContainer: String, bundleID: String) -> [String] {
        ["simctl", "spawn", udid, "defaults", "read", iosPreferencesDomain(dataContainer: dataContainer, bundleID: bundleID)]
    }

    public static func iosPreferencesDomain(dataContainer: String, bundleID: String) -> String {
        URL(fileURLWithPath: dataContainer).appendingPathComponent("Library/Preferences/\(bundleID)").path
    }

    /// `defaults read` prints `EXDevMenuIsOnboardingFinished = 1;` and `EXDevMenuShowsAtLaunch = 0;` once both are written.
    public static func iosDefaultsConfirmed(_ output: String) -> Bool {
        output.contains("\(iosOnboardingKey) = 1;") && output.contains("\(iosShowsAtLaunchKey) = 0;")
    }

    /// Classifies an installed app from what its bundle holds.
    public static func iosBundleError(bundleID: String, hasDevMenu: Bool, hasEmbeddedBundle: Bool) -> ExpoDevClientError? {
        if hasDevMenu { return nil }
        if hasEmbeddedBundle {
            return ExpoDevClientError(
                .releaseBuild,
                "\(bundleID) is a Release build (it embeds main.jsbundle and has no Expo dev menu). Install a Debug build of an app that uses expo-dev-client."
            )
        }
        return ExpoDevClientError(
            .notDevClient,
            "\(bundleID) is not an Expo dev client (no \(iosDevMenuBundle)), so it has no dev menu intro to skip. Plain React Native debug builds need no preparing."
        )
    }

    public static func iosNotInstalled(bundleID: String, udid: String) -> ExpoDevClientError {
        ExpoDevClientError(
            .notInstalled,
            "\(bundleID) is not installed on simulator \(udid). Install the Debug build first (xcrun simctl install \(udid) <path/to/App.app>), then run rn prepare before launching it."
        )
    }

    // MARK: Android

    public static func androidPathCommand(package: String) -> String {
        "pm path \(package)"
    }

    public static func androidPackageDumpCommand(package: String) -> String {
        "dumpsys package \(package)"
    }

    /// The SharedPreferences file belongs to the app, so a debuggable build's `run-as` is the only non-root way to it.
    public static func androidForceStopCommand(package: String) -> String {
        "am force-stop \(package)"
    }

    /// Replaces both keys in place, or creates the file, then prints it so the write can be checked.
    public static func androidWriteCommand(package: String) -> String {
        let onboarding = #"<boolean name=\"\#(androidOnboardingKey)\" value=\"true\" />"#
        let atLaunch = #"<boolean name=\"\#(androidShowsAtLaunchKey)\" value=\"false\" />"#
        let file = androidPreferencesFile
        let script = [
            "f=\(file)",
            "mkdir -p shared_prefs",
            #"if [ -f $f ]; then sed -i -e "s#<boolean name=\"\#(androidOnboardingKey)\"[^>]*/>##" -e "s#<boolean name=\"\#(androidShowsAtLaunchKey)\"[^>]*/>##" -e "s#<map */>#<map></map>#" -e "s#</map>#\#(onboarding)\#(atLaunch)</map>#" $f; "#
                + #"else echo "<?xml version='1.0' encoding='utf-8' standalone='yes' ?><map>\#(onboarding)\#(atLaunch)</map>" > $f; fi"#,
            "cat $f",
        ].joined(separator: " && ")
        return "run-as \(package) sh -c \(shellQuote(script))"
    }

    public static func androidPrefsConfirmed(_ xml: String) -> Bool {
        xml.contains(#"name="\#(androidOnboardingKey)" value="true""#)
            && xml.contains(#"name="\#(androidShowsAtLaunchKey)" value="false""#)
    }

    /// `pm path` prints `package:/data/app/.../base.apk` for an installed package and nothing otherwise.
    public static func androidIsInstalled(pmPathOutput: String) -> Bool {
        pmPathOutput.split(whereSeparator: \.isNewline).contains { $0.hasPrefix("package:") }
    }

    /// expo-dev-launcher's debug manifest adds an activity with an `expo-dev-launcher` link, which dumpsys lists.
    public static func androidIsDevClient(packageDump: String) -> Bool {
        packageDump.contains("expo.modules.devlauncher") || packageDump.contains("expo-dev-launcher")
    }

    public static func androidNotInstalled(package: String, serial: String) -> ExpoDevClientError {
        ExpoDevClientError(
            .notInstalled,
            "\(package) is not installed on \(serial). Install the debug APK first (adb -s \(serial) install -r <app-debug.apk>), then run rn prepare before launching it."
        )
    }

    public static func androidNotDevClient(package: String) -> ExpoDevClientError {
        ExpoDevClientError(
            .notDevClient,
            "\(package) is not an Expo dev client (no expo-dev-launcher activity), so it has no dev menu intro to skip."
        )
    }

    /// Maps `run-as` refusals to what the user must change; nil when the output names no known refusal.
    public static func androidRunAsError(package: String, output: String) -> ExpoDevClientError? {
        let text = output.lowercased()
        if text.contains("not debuggable") {
            return ExpoDevClientError(
                .notDebuggable,
                "\(package) is not debuggable, so its preferences cannot be written. Install the debug APK (a release build has no Expo dev menu)."
            )
        }
        if text.contains("unknown package") {
            return ExpoDevClientError(.notInstalled, "\(package) is not installed. Install the debug APK first.")
        }
        return nil
    }

    static func shellQuote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }
}
