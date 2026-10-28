import ArgumentParser
import Foundation
import OffsiderCore

struct AppLaunchCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "launch",
        abstract: "Launch an installed app, or bring it to the front.",
        discussion: """
        Starts the app as a tap on its icon does: a running app comes to the front (a warm start), a stopped one \
        starts afresh (cold). --restart stops it first, so the start is always cold. Android starts its launcher \
        activity with `am start -W` and reports the launch time; an iPhone or iPad uses `devicectl device process \
        launch`, a simulator `simctl launch`. A locked iPhone refuses with device_locked.

        Example:
          offsider app launch --restart --app com.example.app --device DEVICE_ID
        """
    )

    @OptionGroup
    var appOption: AppTargetOption

    @Flag(help: "Stop the app first, so it starts cold.")
    var restart = false

    @Flag(name: .customLong("json"), help: "Print one JSON object to stdout.")
    var json = false

    @OptionGroup
    var deviceOption: DeviceOption

    func run() async throws {
        let route = try await DeviceRouter.routeForInput(deviceOption, logger: OffsiderLogger())
        let app = try AppTarget.resolve(appOption, route: route, command: "launch")
        let launch = try await Console.current.progress(restart ? "Restarting \(app)" : "Launching \(app)") {
            let backend = try await AppTarget.backend(route, app: app)
            try await route.backend.prepare()
            let id = try await route.backend.requireBootedDevice(route.device).id
            return try await backend.launchApp(app, restart: restart, on: id)
        }
        await DeviceActivityLedger.current.recordInput(on: route.device)
        let verb = restart ? "Restarted" : "Launched"
        let text = json ? AppReport.launch(launch, action: "launch", on: route.device) : AppTarget.launchLine(verb, launch)
        DevicePersonView.emit(text, json: json, person: DevicePersonView.receipt("\(verb) \(app)", aside: AppTarget.launchAside(launch)), console: .current)
    }
}
