import ArgumentParser
import OffsiderIOSDevice

/// `--app`: the app a physical iPhone or iPad reads, since its runner cannot always tell which app is in front.
struct AppOption: ParsableArguments {
    @Option(
        name: .customLong("app"),
        help: ArgumentHelp(
            "On a physical iPhone or iPad, read this app (its bundle ID) instead of the frontmost one; later commands remember it. Simulators and Android ignore it.",
            valueName: "bundle-id"
        )
    )
    var bundleID: String?

    /// Hands the app to a phone's backend; other backends never see it. True when the phone's app changed.
    @MainActor
    @discardableResult
    func apply(to route: DeviceRouter.Route) -> Bool {
        guard let bundleID, let phone = route.backend as? IOSDeviceBackend, phone.targetApp != bundleID else { return false }
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
