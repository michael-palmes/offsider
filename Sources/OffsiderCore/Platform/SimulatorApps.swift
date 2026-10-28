import Foundation

/// `simctl` calls for one app on a simulator, and the parsers for what they print.
public enum SimulatorApps {
    public static func appInfoArguments(udid: String, bundleID: String) -> [String] {
        ["simctl", "appinfo", udid, bundleID]
    }

    public static func launchArguments(udid: String, bundleID: String, restart: Bool) -> [String] {
        ["simctl", "launch"] + (restart ? ["--terminate-running-process"] : []) + [udid, bundleID]
    }

    public static func launchctlListArguments(udid: String) -> [String] {
        ["simctl", "spawn", udid, "launchctl", "list"]
    }

    /// `simctl appinfo`'s property list (OpenStep text); nil when it does not parse or names another app.
    public static func info(_ output: String, bundleID: String) -> AppInfo? {
        guard let data = output.data(using: .utf8),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              plist["CFBundleIdentifier"] as? String == bundleID else { return nil }
        let text: (String) -> String? = { key in (plist[key] as? String).flatMap { $0.isEmpty ? nil : $0 } }
        return AppInfo(
            app: bundleID,
            name: text("CFBundleDisplayName") ?? text("CFBundleName"),
            version: text("CFBundleShortVersionString"),
            build: text("CFBundleVersion")
        )
    }

    /// The app's process from `launchctl list` (`63513  0  UIKitApplication:com.example.app[58a4][rb-legacy]`); nil when it is not running.
    public static func runningPID(_ output: String, bundleID: String) -> Int? {
        let label = "UIKitApplication:\(bundleID)["
        for line in output.split(whereSeparator: \.isNewline) {
            let columns = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard columns.count >= 3, columns[2].hasPrefix(label), let pid = Int(columns[0]), pid > 0 else { continue }
            return pid
        }
        return nil
    }

    /// `simctl launch`'s `com.example.app: 63513`.
    public static func launchedPID(_ output: String, bundleID: String) -> Int? {
        output.split(whereSeparator: \.isNewline).lazy.compactMap { line -> Int? in
            guard line.hasPrefix("\(bundleID): ") else { return nil }
            return Int(line.dropFirst(bundleID.count + 2).trimmingCharacters(in: .whitespaces))
        }.first
    }

    /// `simctl terminate` exits 3 with "found nothing to terminate" for an app that is not running.
    public static func nothingToTerminate(status: Int32, stderr: String) -> Bool {
        status != 0 && stderr.contains("found nothing to terminate")
    }

    /// `simctl appinfo` and `get_app_container` say "No application record" or "No such file" for an app that is not installed.
    public static func notInstalled(stderr: String) -> Bool {
        stderr.contains("No application record") || stderr.contains("Application not found") || stderr.contains("No such file or directory")
    }

    /// `simctl openurl` exits 115 (LSApplicationWorkspaceErrorDomain) when no app claims the link.
    public static func linkUnclaimed(status: Int32, stderr: String) -> Bool {
        status == 115 || stderr.contains("LSApplicationWorkspaceErrorDomain error 115")
    }
}
