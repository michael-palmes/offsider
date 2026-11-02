import ArgumentParser
import Foundation
import OffsiderCore

struct AppCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "app",
        abstract: "Read, launch, stop, install, remove or message one app.",
        discussion: """
        Each action names one app (--app, else offsider.login.json's bundleId or package, else a physical device's only \
        pinned app) and reaches nothing else on the device. On a physical device the app must be one its allowance \
        permits: browsers, home screens, system apps and apps managed policy denies are refused (app_not_allowed). \
        info and prefs only read; the others lock the device like input. install, uninstall, prefs and broadcast are Android only; \
        on a phone, install and uninstall also need the app pinned by name, or a test device.

        Examples:
          offsider app info --app com.example.app --device DEVICE_ID
          offsider app launch --restart --app com.example.app --device DEVICE_ID
          offsider app stop --app com.example.app --device DEVICE_ID
          offsider app open 'https://example.com/offer?id=7&ref=push' --app com.example.app --device DEVICE_ID
          offsider app install build/app-debug.apk --device DEVICE_ID
          offsider app prefs --app com.example.app --device DEVICE_ID
          offsider app broadcast com.example.app.action.REFRESH --app com.example.app --device DEVICE_ID
        """,
        subcommands: [
            AppInfoCommand.self, AppLaunchCommand.self, AppStopCommand.self, AppOpenCommand.self,
            AppInstallCommand.self, AppUninstallCommand.self, AppPrefsCommand.self, AppBroadcastCommand.self,
        ]
    )
}

/// `--app` for the `app` commands, which act on one app and need it named.
struct AppTargetOption: ParsableArguments {
    @Option(
        name: .customLong("app"),
        help: ArgumentHelp(
            "The app's bundle ID or Android package (default offsider.login.json's, else a physical device's only pinned app).",
            valueName: "bundle-id"
        ),
        transform: AppID.parse
    )
    var bundleID: String?
}

enum AppTarget {
    /// `--app`, else offsider.login.json's app for the platform, else the allowance's only pinned app; then the allowance must permit it.
    static func resolve(
        _ option: AppTargetOption, route: DeviceRouter.Route, command: String, gate: DevicePolicyGate = .current,
        profile: () throws -> LoginProfile? = { try LoginProfiles.implicit() }
    ) throws -> String {
        try route.app(named: option.bundleID, gate: gate, profile: profile) {
            CLIError(
                errorDescription: "app \(command) needs the app: pass --app <\(route.device.platform == .ios ? "bundle-id" : "package")>, or name it in offsider.login.json.",
                reason: .usage,
                hint: "offsider app \(command) --app <id> --device \(route.device.rawValue)"
            )
        }
    }

    /// A phone allowed for any app reads only the app a command names, so the backend learns it too.
    @MainActor
    static func backend(_ route: DeviceRouter.Route, app: String) throws -> any AppLifecycleControlling {
        guard let backend = route.backend as? any AppLifecycleControlling else {
            throw CLIError(errorDescription: "The app commands are not available for \(route.device.rawValue).", reason: .notSupported)
        }
        (route.backend as? any AppTargetSelecting)?.selectApp(app, on: route.device)
        return backend
    }

    /// The Android backend, for the commands only it has.
    @MainActor
    static func manager(_ route: DeviceRouter.Route, app: String) throws -> any AppManaging {
        guard let backend = route.backend as? any AppManaging else {
            throw CLIError(errorDescription: "This command is Android only, and \(route.device.rawValue) is not an Android device.", reason: .notSupported)
        }
        (route.backend as? any AppTargetSelecting)?.selectApp(app, on: route.device)
        return backend
    }

    /// Installing and removing replace or delete an app's data, so a phone allowed for any app still needs this one pinned by name; a test device does not.
    static func requirePinned(_ app: String, route: DeviceRouter.Route, command: String, gate: DevicePolicyGate = .current) throws {
        guard let allowance = route.allowance, !gate.policy().drivesWhole(allowance), !allowance.pinnedApps.contains(app) else { return }
        let audience = ErrorAudience.current
        throw CLIError(
            errorDescription: "app \(command) changes an app's data, so \(app) must be pinned by name on \(allowance.name) (\(allowance.key)). Nothing was sent."
                + audience.personStep("offsider devices add", agentTail: ", choose \(allowance.name) (\(allowance.key)) and pin \(app)"),
            reason: .appNotAllowed,
            hint: "offsider devices add"
        )
    }

    /// `cold start, 412 ms`, `warm`, or nil when the platform did not say.
    static func launchAside(_ launch: AppLaunch) -> String? {
        let start = launch.start.map { "\($0.rawValue) start" }
        let time = launch.milliseconds.map { "\($0) ms" }
        let parts = [start, time].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    /// One line for an agent: `Launched com.example.app (cold start, 412 ms, pid 4021).`
    static func launchLine(_ verb: String, _ launch: AppLaunch) -> String {
        let details = [launchAside(launch), launch.pid.map { "pid \($0)" }].compactMap { $0 }
        return "\(verb) \(launch.app)" + (details.isEmpty ? "" : " (\(details.joined(separator: ", ")))") + "."
    }
}
