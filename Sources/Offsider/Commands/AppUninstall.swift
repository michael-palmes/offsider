import ArgumentParser
import Foundation
import OffsiderCore

struct AppUninstallCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "uninstall",
        abstract: "Remove an app and its data.",
        discussion: """
        Deletes the app's data too: `pm uninstall <package>` on Android, `devicectl device uninstall app` on an iPhone \
        or iPad, `simctl uninstall` on a simulator. An app that is not installed is no error; the output says so. On a \
        phone, iPhone or iPad the app must be pinned by name: allowing any app is not enough. Removing an App Store or \
        TestFlight copy from an iPhone or iPad in personal use needs a person at the Mac (Touch ID); iOS keeps an \
        app's Keychain items after it is removed.

        Example:
          offsider app uninstall --app com.example.app --device DEVICE_ID
        """
    )

    @OptionGroup
    var appOption: AppTargetOption

    @Flag(name: .customLong("json"), help: "Print one JSON object to stdout.")
    var json = false

    @OptionGroup
    var deviceOption: DeviceOption

    @MainActor
    func run() async throws {
        switch DeviceIDClassifier.classify(deviceOption.id) {
        case .iosSimulator, .iosDevice: try await removeBundle()
        default: try await removePackage()
        }
    }

    @MainActor
    private func removePackage() async throws {
        let route = try await DeviceRouter.routeForInput(deviceOption, logger: OffsiderLogger())
        let app = try AppTarget.resolve(appOption, route: route, command: "uninstall")
        try AppTarget.requirePinned(app, route: route, command: "uninstall")
        let result = try await Console.current.progress("Removing \(app)") {
            let backend = try AppTarget.manager(route, app: app)
            try await route.backend.prepare()
            let id = try await route.backend.requireBootedDevice(route.device).id
            return try await backend.uninstallApp(app, on: id)
        }
        report(result, on: route.device)
    }

    @MainActor
    func report(_ result: AppUninstall, on device: DeviceID) {
        DeviceActivityLedger.current.recordInput(on: device)
        let headline = result.wasInstalled ? "Removed \(result.app)" : "\(result.app) was not installed"
        let text = json ? AppManagementReport.uninstall(result, on: device) : headline + "."
        DevicePersonView.emit(text, json: json, person: DevicePersonView.receipt(headline), console: .current)
    }
}
