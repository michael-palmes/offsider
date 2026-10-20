import ArgumentParser
import OffsiderAndroid
import OffsiderIOSDevice

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
        guard let bundleID else { return false }
        if let android = route.backend as? AndroidBackend {
            return android.selectApp(bundleID, on: route.device.rawValue)
        }
        guard let phone = route.backend as? IOSDeviceBackend, phone.targetApp != bundleID else { return false }
        phone.targetApp = bundleID
        return true
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
