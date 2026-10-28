import Foundation
import OffsiderCore

/// One app's row from `devicectl device info apps --bundle-id`, and its process from `device info processes`.
public enum DevicectlAppProcess {
    /// Developer and App Store or TestFlight apps alike, narrowed to one bundle ID on the device.
    public static func infoArguments(udid: String, bundleID: String) -> [String] {
        ["device", "info", "apps", "--device", udid, "--include-default-apps", "--bundle-id", bundleID, "--timeout", "20", "--json-output", "-", "-q"]
    }

    public static func processesArguments(udid: String) -> [String] {
        ["device", "info", "processes", "--device", udid, "--timeout", "20", "--json-output", "-", "-q"]
    }

    /// `--payload-url` hands the link to this app alone, as an open-URL call.
    public static func launchArguments(udid: String, bundleID: String, restart: Bool, url: String? = nil) -> [String] {
        ["device", "process", "launch", "--device", udid]
            + (restart ? ["--terminate-existing"] : [])
            + (url.map { ["--payload-url", $0] } ?? [])
            + ["--timeout", "30", "--json-output", "-", "-q", bundleID]
    }

    public static func terminateArguments(udid: String, pid: Int) -> [String] {
        ["device", "process", "terminate", "--device", udid, "--pid", String(pid), "--timeout", "20", "--json-output", "-", "-q"]
    }

    /// The installed app and its bundle's location; nil when the device lists no app with that ID.
    public struct App: Equatable, Sendable {
        public let info: AppInfo
        public let bundleURL: String?
    }

    public static func app(_ data: Data, bundleID: String) throws -> App? {
        let result = try resultObject(data)
        guard let rows = result["apps"] as? [[String: Any]] else {
            throw DevicectlDeviceList.ParseError(detail: "no result.apps in the devicectl reply")
        }
        guard let row = rows.first(where: { $0["bundleIdentifier"] as? String == bundleID }) else { return nil }
        let text: (String) -> String? = { key in (row[key] as? String).flatMap { $0.isEmpty ? nil : $0 } }
        let info = AppInfo(
            app: bundleID, name: text("name"), version: text("version"), build: text("bundleVersion"),
            installer: row["builtByDeveloper"] as? Bool == true ? "developer" : nil
        )
        return App(info: info, bundleURL: text("url"))
    }

    /// The first process whose executable sits inside the app's bundle.
    public static func pid(_ data: Data, bundleURL: String) throws -> Int? {
        let result = try resultObject(data)
        guard let rows = result["runningProcesses"] as? [[String: Any]] else {
            throw DevicectlDeviceList.ParseError(detail: "no result.runningProcesses in the devicectl reply")
        }
        let bundle = bundleURL.hasSuffix("/") ? bundleURL : bundleURL + "/"
        for row in rows {
            guard let executable = row["executable"] as? String, executable.hasPrefix(bundle),
                  let pid = (row["processIdentifier"] as? NSNumber)?.intValue, pid > 0 else { continue }
            return pid
        }
        return nil
    }

    /// `result.process.processIdentifier` of a launch.
    public static func launchedPID(_ data: Data) -> Int? {
        guard let result = try? resultObject(data), let process = result["process"] as? [String: Any] else { return nil }
        return (process["processIdentifier"] as? NSNumber)?.intValue
    }

    private static func resultObject(_ data: Data) throws -> [String: Any] {
        guard let start = data.firstIndex(of: UInt8(ascii: "{")),
              let root = try? JSONSerialization.jsonObject(with: data[start...]) as? [String: Any] else {
            throw DevicectlDeviceList.ParseError(detail: "the devicectl reply is not valid JSON")
        }
        if let outcome = (root["info"] as? [String: Any])?["outcome"] as? String, outcome != "success" {
            throw DevicectlDeviceList.ParseError(detail: "devicectl reported \(outcome)")
        }
        guard let result = root["result"] as? [String: Any] else {
            throw DevicectlDeviceList.ParseError(detail: "no result in the devicectl reply")
        }
        return result
    }
}
