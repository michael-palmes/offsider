import ArgumentParser
import Foundation
import OffsiderCore

struct AppUninstallCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "uninstall",
        abstract: "Remove an app and its data.",
        discussion: """
        Android only. `pm uninstall <package>`, which also deletes the app's data. An app that is not installed is no \
        error; the output says so. On a phone the app must be pinned by name: allowing any app is not enough.

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

    func run() async throws {
        try StayAwakeCommand.requireAndroid(deviceOption.id, command: "app uninstall")
        let route = try await DeviceRouter.routeForInput(deviceOption, logger: OffsiderLogger())
        let app = try AppTarget.resolve(appOption, route: route, command: "uninstall")
        try AppTarget.requirePinned(app, route: route, command: "uninstall")
        let result = try await Console.current.progress("Removing \(app)") {
            let backend = try await AppTarget.manager(route, app: app)
            try await route.backend.prepare()
            let id = try await route.backend.requireBootedDevice(route.device).id
            return try await backend.uninstallApp(app, on: id)
        }
        await DeviceActivityLedger.current.recordInput(on: route.device)
        let headline = result.wasInstalled ? "Removed \(app)" : "\(app) was not installed"
        let text = json ? AppManagementReport.uninstall(result, on: route.device) : headline + "."
        DevicePersonView.emit(text, json: json, person: DevicePersonView.receipt(headline), console: .current)
    }
}
