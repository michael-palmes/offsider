import ArgumentParser
import Foundation
import OffsiderCore

struct AppStopCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "stop",
        abstract: "Stop a running app.",
        discussion: """
        Ends the app's process: `am force-stop` on Android (which also clears its notifications and alarms, as \
        Settings' Force stop does), `simctl terminate` on a simulator, `devicectl device process terminate` on an \
        iPhone or iPad. An app that is not running is no error; the output says so.

        Example:
          offsider app stop --app com.example.app --device DEVICE_ID
        """
    )

    @OptionGroup
    var appOption: AppTargetOption

    @Flag(name: .customLong("json"), help: "Print one JSON object to stdout.")
    var json = false

    @OptionGroup
    var deviceOption: DeviceOption

    func run() async throws {
        let route = try await DeviceRouter.routeForInput(deviceOption, logger: OffsiderLogger())
        let app = try AppTarget.resolve(appOption, route: route, command: "stop")
        let stop = try await Console.current.progress("Stopping \(app)") {
            let backend = try await AppTarget.backend(route, app: app)
            try await route.backend.prepare()
            let id = try await route.backend.requireBootedDevice(route.device).id
            return try await backend.terminateApp(app, on: id)
        }
        await DeviceActivityLedger.current.recordInput(on: route.device)
        let text = json ? AppReport.stop(stop, on: route.device) : Self.line(stop)
        let headline = stop.wasRunning == false ? "\(app) was not running" : "Stopped \(app)"
        DevicePersonView.emit(text, json: json, person: DevicePersonView.receipt(headline), console: .current)
    }

    static func line(_ stop: AppStop) -> String {
        switch stop.wasRunning {
        case true?: return "Stopped \(stop.app)."
        case false?: return "\(stop.app) was not running; nothing to stop."
        case nil: return "Stopped \(stop.app), if it was running."
        }
    }
}
