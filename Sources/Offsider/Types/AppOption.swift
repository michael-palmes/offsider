import ArgumentParser
import OffsiderCore

/// `--app`: the one app a physical iPhone, iPad or Android phone is driven inside, checked in front before every frame and input.
struct AppOption: ParsableArguments {
    @Option(
        name: .customLong("app"),
        help: ArgumentHelp(
            "On a physical iPhone, iPad or Android phone, the app (bundle ID or package) this command reads and drives; it must be an allowed app, and Offsider checks it is in front before every frame and input. Simulators and emulators ignore it.",
            valueName: "bundle-id"
        )
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
    func app(named: String?, gate: DevicePolicyGate, profile: () -> LoginProfile?, missing: () -> CLIError) throws -> String {
        let pinned = allowance.flatMap { $0.pinnedApps.count == 1 ? $0.pinnedApps[0] : nil }
        guard let app = named ?? Logs.profileApp(profile(), platform: device.platform) ?? pinned else { throw missing() }
        if let allowance { try gate.requireApp(app, on: allowance) }
        return app
    }
}

/// A command that takes `--app`, so a batch step can apply it too.
protocol AppTargeting {
    var appOption: AppOption { get }
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
