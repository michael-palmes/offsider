import ArgumentParser
import Foundation
import OffsiderCore

struct AppInfoCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "info",
        abstract: "Show an installed app's version, build and install details.",
        discussion: """
        Reads one app only: `simctl appinfo` on a simulator, `devicectl device info apps --bundle-id` on an iPhone or \
        iPad, `dumpsys package <package>` on Android. Android adds the installer (com.android.vending is Google Play; \
        none for adb), first install and last update times, whether it is debuggable and, from Android 13, whether it \
        may post notifications. An iPhone app built and installed by a developer reads installer `developer`. Fields \
        a platform does not report are null in JSON.

        Example:
          offsider app info --app com.example.app --device DEVICE_ID --json
        """
    )

    @OptionGroup
    var appOption: AppTargetOption

    @Flag(name: .customLong("json"), help: "Print one JSON object to stdout.")
    var json = false

    @OptionGroup
    var deviceOption: ReadDeviceOption

    func run() async throws {
        let route = try await DeviceRouter.route(deviceOption.id, logger: OffsiderLogger())
        let app = try AppTarget.resolve(appOption, route: route, command: "info")
        let info = try await Console.current.progress("Reading \(app)") {
            let backend = try await AppTarget.backend(route, app: app)
            try await route.backend.prepare()
            let id = try await route.backend.requireBootedDevice(route.device).id
            return try await backend.appInfo(app, on: id)
        }
        let text = json ? AppReport.info(info, on: route.device) : Self.lines(info)
        DevicePersonView.emit(text, json: json, person: Self.person(info), console: .current)
    }

    static func lines(_ info: AppInfo) -> String {
        var lines = ["\(info.app)" + (info.name.map { " (\(TerminalText.field($0)))" } ?? "")]
        for row in rows(info) { lines.append("  \(row.label): \(row.value)") }
        return lines.joined(separator: "\n")
    }

    static func person(_ info: AppInfo) -> [Block] {
        let title = info.name.map { TerminalText.field($0) } ?? info.app
        let fields = rows(info).map { Field($0.label, Table.Cell($0.value, untrusted: $0.untrusted)) }
        return [.header(Header(.app, title, info.name == nil ? [] : [info.app])), .fields(fields)]
    }

    /// Only what the platform reported, in a fixed order.
    static func rows(_ info: AppInfo) -> [(label: String, value: String, untrusted: Bool)] {
        let version = [info.version.map { TerminalText.field($0) }, info.build.map { "build \(TerminalText.field($0))" }].compactMap { $0 }
        var rows: [(label: String, value: String, untrusted: Bool)] = []
        if !version.isEmpty { rows.append(("Version", version.joined(separator: ", "), true)) }
        if let installer = info.installer { rows.append(("Installer", installerName(installer), true)) }
        if let date = info.firstInstalled { rows.append(("Installed", ProcessStamp.timestamp(date), false)) }
        if let date = info.lastUpdated { rows.append(("Updated", ProcessStamp.timestamp(date), false)) }
        if let notifications = info.notifications { rows.append(("Notifications", notifications ? "granted" : "denied", false)) }
        if let debuggable = info.debuggable { rows.append(("Build", debuggable ? "debuggable" : "release", false)) }
        return rows
    }

    static func installerName(_ installer: String) -> String {
        switch installer {
        case "com.android.vending": return "Google Play (com.android.vending)"
        case "developer": return "a developer (Xcode or devicectl)"
        default: return TerminalText.field(installer)
        }
    }
}
