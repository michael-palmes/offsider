import Foundation

/// Optional capability: marking an Expo dev client's first-launch intro as seen before the app starts.
@MainActor
public protocol ExpoDevClientPreparing: DeviceBackend {
    func prepareExpoDevClient(_ appID: String, on id: DeviceID) async throws
}

/// Optional capability: sending an Expo dev client the link that loads a bundle from Metro.
@MainActor
public protocol ExpoDevClientOpening: DeviceBackend {
    /// The `exp+` schemes the installed app registers.
    func devClientSchemes(_ appID: String, on id: DeviceID) async throws -> [String]
    /// The host the device reaches Metro on: loopback, or the emulator's alias for the Mac.
    func metroHost(port: Int, on id: DeviceID) async throws -> String
    func openURL(_ url: String, appID: String, on id: DeviceID) async throws
}

public struct ExpoDevClientError: Error, CustomStringConvertible, LocalizedError, Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case invalidAppID
        case notInstalled
        case releaseBuild
        case notDebuggable
        case notDevClient
        case writeFailed
        case noScheme
        case noRoute
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

    // MARK: Opening

    /// The emulator's alias for the Mac's loopback, used when no `adb reverse` maps the port.
    public static let emulatorHostAlias = "10.0.2.2"
    public static let loopback = "127.0.0.1"

    /// `<scheme>://expo-development-client/?url=<http://host:port, percent-encoded>`, as `expo start --dev-client` prints it.
    public static func devClientURL(scheme: String, host: String, port: Int) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let metro = "http://\(host):\(port)".addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
        return "\(scheme)://expo-development-client/?url=\(metro)"
    }

    /// The `exp+` schemes among `dumpsys package` lines such as `Scheme: "exp+offsiderplaygroundrn"`, in order, once each.
    public static func schemes(fromPackageDump dump: String) -> [String] {
        var found: [String] = []
        for line in dump.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("Scheme: \"") else { continue }
            let scheme = trimmed.dropFirst("Scheme: \"".count).prefix { $0 != "\"" }
            if scheme.hasPrefix("exp+"), !found.contains(String(scheme)) {
                found.append(String(scheme))
            }
        }
        return found
    }

    /// The `exp+` schemes in an app's `Info.plist` `CFBundleURLTypes`.
    public static func schemes(fromInfoPlist data: Data) -> [String] {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let types = plist["CFBundleURLTypes"] as? [[String: Any]] else { return [] }
        var found: [String] = []
        for scheme in types.flatMap({ $0["CFBundleURLSchemes"] as? [String] ?? [] }) where scheme.hasPrefix("exp+") && !found.contains(scheme) {
            found.append(scheme)
        }
        return found
    }

    /// The one `exp+` scheme, or an error that names `--scheme`.
    public static func singleScheme(_ schemes: [String], appID: String) throws -> String {
        guard schemes.count == 1 else {
            let listed = schemes.isEmpty ? "no exp+ scheme" : "\(schemes.count) exp+ schemes (\(schemes.joined(separator: ", ")))"
            throw ExpoDevClientError(.noScheme, "\(appID) registers \(listed), so Offsider cannot tell which link opens its dev client. Pass --scheme exp+<slug>.")
        }
        return schemes[0]
    }

    /// Loopback when `adb reverse` maps the port (lines such as `emulator-5554 tcp:8081 tcp:8081`), else the emulator's alias for the Mac; nil for a phone without one.
    public static func androidMetroHost(reverseList: String, port: Int, isEmulator: Bool) -> String? {
        let mapped = reverseList.split(whereSeparator: \.isNewline).contains { line in
            line.split(separator: " ").dropFirst().first == "tcp:\(port)"
        }
        if mapped { return loopback }
        return isEmulator ? emulatorHostAlias : nil
    }

    public static func androidOpenCommand(url: String, package: String) -> String {
        "am start -W -a android.intent.action.VIEW -d \(shellQuote(url)) \(package)"
    }

    public static func iosOpenURLArguments(udid: String, url: String) -> [String] {
        ["simctl", "openurl", udid, url]
    }
}

/// The Expo dev launcher and React Native's loading states, read from the tree.
public enum ExpoDevLauncher {
    /// The launcher: `Development Build` with its server search or its recent list.
    public static func isLauncher(_ tree: UITree) -> Bool {
        let labels = texts(in: tree)
        return labels.contains { $0 == "Development Build" }
            && labels.contains { $0.hasPrefix("Searching for development servers") || $0 == "RECENTLY OPENED" || $0 == "Recently opened" }
    }

    /// A load failure: the dev client's error screen or React Native's red box.
    public static func loadError(in tree: UITree) -> String? {
        texts(in: tree).first { text in
            text.contains("There was a problem loading the project") || text.contains("Unable to load script") || text.contains("Could not connect to development server")
        }
    }

    /// The Open button of the `Open in “App”?` alert an iOS 27 simulator shows before it follows a custom-scheme link.
    public static func openLinkPrompt(in tree: UITree) -> UINode? {
        let nodes = tree.roots.flatMap { $0.flattened() }
        guard let alert = nodes.first(where: { node in
            let text = node.label?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return text.hasPrefix("Open in “") && text.hasSuffix("”?")
        }), let box = alert.frame else { return nil }
        return nodes.first { node in
            guard node.role == .button, node.label == "Open", let frame = node.frame else { return false }
            return box.contains(frame.center)
        }
    }

    /// The `Bundling` or `Downloading` banner while Metro sends the bundle.
    public static func isLoading(_ tree: UITree) -> Bool {
        texts(in: tree).contains { $0.hasPrefix("Bundling") || $0.hasPrefix("Downloading") }
    }

    private static func texts(in tree: UITree) -> [String] {
        tree.roots.flatMap { $0.flattened() }.flatMap { [$0.label, $0.value] }.compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
    }
}
