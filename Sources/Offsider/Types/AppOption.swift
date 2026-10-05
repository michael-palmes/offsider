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

    /// Hands the app to a phone's backend; other backends never see it.
    @MainActor
    func apply(to route: DeviceRouter.Route) {
        guard let bundleID, let phone = route.backend as? IOSDeviceBackend else { return }
        phone.targetApp = bundleID
    }
}
