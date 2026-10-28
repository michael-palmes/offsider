import ArgumentParser
import Foundation
import OffsiderCore

struct AppCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "app",
        abstract: "Read, launch, stop or send a link to one installed app.",
        discussion: """
        Each action names one app (--app, else offsider.login.json's bundleId or package, else a physical device's only \
        pinned app) and reaches nothing else on the device. On a physical device the app must be one its allowance \
        permits: browsers, home screens, system apps and apps managed policy denies are refused (app_not_allowed). \
        info only reads; launch, stop and open lock the device like input.

        Examples:
          offsider app info --app com.example.app --device DEVICE_ID
          offsider app launch --restart --app com.example.app --device DEVICE_ID
          offsider app stop --app com.example.app --device DEVICE_ID
          offsider app open 'https://example.com/offer?id=7&ref=push' --app com.example.app --device DEVICE_ID
        """,
        subcommands: [AppInfoCommand.self, AppLaunchCommand.self, AppStopCommand.self, AppOpenCommand.self]
    )
}

/// `--app` for the `app` commands, which act on one app and need it named.
struct AppTargetOption: ParsableArguments {
    @Option(
        name: .customLong("app"),
        help: ArgumentHelp(
            "The app's bundle ID or Android package (default offsider.login.json's, else a physical device's only pinned app).",
            valueName: "bundle-id"
        )
    )
    var bundleID: String?

    func validate() throws {
        guard let bundleID else { return }
        do {
            _ = try ExpoDevClient.validate(appID: bundleID)
        } catch {
            throw ValidationError(error.localizedDescription)
        }
    }
}

enum AppTarget {
    /// `--app`, else offsider.login.json's app for the platform, else the allowance's only pinned app; then the allowance must permit it.
    static func resolve(
        _ option: AppTargetOption, route: DeviceRouter.Route, command: String, gate: DevicePolicyGate = .current,
        profile: () -> LoginProfile? = { (try? LoginProfiles.load(project: nil, warn: { _ in })) ?? nil }
    ) throws -> String {
        let platform = route.device.platform
        let pinned = route.allowance.flatMap { $0.pinnedApps.count == 1 ? $0.pinnedApps[0] : nil }
        let named = option.bundleID ?? profile().flatMap { platform == .ios ? $0.bundleID : $0.package }.flatMap { $0.isEmpty ? nil : $0 }
        guard let app = named ?? pinned else {
            throw CLIError(
                errorDescription: "app \(command) needs the app: pass --app <\(platform == .ios ? "bundle-id" : "package")>, or name it in offsider.login.json.",
                reason: .usage,
                hint: "offsider app \(command) --app <id> --device \(route.device.rawValue)"
            )
        }
        if let allowance = route.allowance { try gate.requireApp(app, on: allowance) }
        return app
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
