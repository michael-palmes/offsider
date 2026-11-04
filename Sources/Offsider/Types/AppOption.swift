import ArgumentParser
import OffsiderCore

/// `--app` and `--bundle-id`: a malformed or padded id stops at parsing, before any device is named.
enum AppID {
    static func parse(_ text: String) throws -> String {
        try ExpoDevClient.validate(appID: text)
    }
}

/// A command that names one app, which routing checks against a phone's allowance before anything reaches it.
protocol AppNaming {
    var namedApp: String? { get }
}

/// `--app`: the one app a physical iPhone, iPad or Android phone is driven inside, checked in front before every input, and at most every 1 s on Android or 2 s on an iPhone for video frames.
struct AppOption: ParsableArguments {
    @Option(
        name: .customLong("app"),
        help: ArgumentHelp(
            "On a physical iPhone, iPad or Android phone, the app (bundle ID or package) this command reads and drives; it must be an allowed app, and Offsider checks it is in front before every input, and at most every 1 s on Android or 2 s on an iPhone for video frames. Simulators and emulators ignore it.",
            valueName: "bundle-id"
        ),
        transform: AppID.parse
    )
    var bundleID: String?

    /// Hands the app to a phone's backend; other backends never see it. True when the phone's app changed.
    @MainActor
    @discardableResult
    func apply(to route: DeviceRouter.Route) -> Bool {
        guard let bundleID, let phone = route.backend as? any AppTargetSelecting else { return false }
        return phone.selectApp(bundleID, on: route.device)
    }
}

extension DeviceRouter.Route {
    /// The one app a command acts on: `named`, else offsider.login.json's for this platform, else the allowance's only pinned app; then the allowance must permit it. `missing` is the usage error when none names one.
    func app(named: String?, gate: DevicePolicyGate, profile: () throws -> LoginProfile?, missing: () -> CLIError) throws -> String {
        let pinned = allowance.flatMap { $0.pinnedApps.count == 1 ? $0.pinnedApps[0] : nil }
        guard let app = try named ?? Logs.profileApp(try profile(), platform: device.platform) ?? pinned else { throw missing() }
        if let allowance { try gate.requireApp(app, on: allowance) }
        return app
    }

    /// ` --app <id>` for a printed command on a phone where a new process would not know the app: allowed for any app, or for several. Empty elsewhere.
    @MainActor
    var appArgument: String {
        guard let allowance, allowance.pinnedApps.count != 1,
              let app = (backend as? any AppTargetSelecting)?.selectedApp(on: device),
              (try? ExpoDevClient.validate(appID: app)) != nil else { return "" }
        return " --app \(app)"
    }
}

/// A command that takes `--app`, so a batch step can apply it too.
protocol AppTargeting: AppNaming {
    var appOption: AppOption { get }
}

extension AppTargeting {
    var namedApp: String? { appOption.bundleID }
}

extension Tap: AppTargeting {}
extension Type: AppTargeting {}
extension Wait: AppTargeting {}
extension Assert: AppTargeting {}
extension DescribeUI: AppTargeting {}
extension Screenshot: AppTargeting {}
extension Swipe: AppTargeting {}
extension Drag: AppTargeting {}
extension Gesture: AppTargeting {}
extension Touch: AppTargeting {}
extension Slider: AppTargeting {}
extension Key: AppTargeting {}
extension KeySequence: AppTargeting {}
extension KeyCombo: AppTargeting {}
extension Button: AppTargeting {}
extension RNDevMenu: AppTargeting {}
extension RNToolsOff: AppTargeting {}
extension RNLogBoxStatus: AppTargeting {}
extension RNLogBoxOpen: AppTargeting {}
extension RNLogBoxDismiss: AppTargeting {}
extension Turnstile: AppTargeting {}
extension Batch: AppTargeting {}
extension RecordVideo: AppTargeting {}
extension StreamVideo: AppTargeting {}
extension LoginCommand: AppTargeting {}
extension AppInfoCommand: AppNaming { var namedApp: String? { appOption.bundleID } }
extension AppLaunchCommand: AppNaming { var namedApp: String? { appOption.bundleID } }
extension AppStopCommand: AppNaming { var namedApp: String? { appOption.bundleID } }
extension AppOpenCommand: AppNaming { var namedApp: String? { appOption.bundleID } }
extension AppInstallCommand: AppNaming { var namedApp: String? { appOption.bundleID } }
extension AppUninstallCommand: AppNaming { var namedApp: String? { appOption.bundleID } }
extension AppPrefsCommand: AppNaming { var namedApp: String? { appOption.bundleID } }
extension AppBroadcastCommand: AppNaming { var namedApp: String? { appOption.bundleID } }
extension NotificationsCommand: AppNaming { var namedApp: String? { app } }
extension Logs: AppNaming { var namedApp: String? { app } }
extension PermissionCommand: AppNaming { var namedApp: String? { app } }
extension RNPrepare: AppNaming { var namedApp: String? { bundleID } }
extension RNOpen: AppNaming { var namedApp: String? { bundleID } }
