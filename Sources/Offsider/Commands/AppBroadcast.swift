import ArgumentParser
import Foundation
import OffsiderCore

struct AppBroadcastCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "broadcast",
        abstract: "Send a broadcast to one app's own receivers.",
        discussion: """
        Android only. `am broadcast -p <package>`, or `-n <package>/<receiver>` with --receiver, so nothing else on the \
        device hears it; a stopped app still gets it. This is how to refresh a home-screen widget: send the action the \
        widget's provider declares. Android keeps system actions such as APPWIDGET_UPDATE from the shell, which exits 1 \
        with broadcast_refused and lists the app's own actions. A receiver that is not exported exits 1 too, as Android \
        would drop it silently, and a --receiver the app lacks exits 1 with receiver_not_found. Takes no extras.

        Examples:
          offsider app broadcast com.example.app.action.REFRESH --app com.example.app --device DEVICE_ID
          offsider app broadcast com.example.app.action.REFRESH --receiver .RefreshReceiver --app com.example.app --device DEVICE_ID
        """
    )

    @Argument(help: ArgumentHelp("The action the app's receiver declares.", valueName: "action"))
    var action: String

    @Option(name: .customLong("receiver"), help: ArgumentHelp("One receiver class in the app, such as .RefreshReceiver.", valueName: "class"))
    var receiver: String?

    @OptionGroup
    var appOption: AppTargetOption

    @Flag(name: .customLong("json"), help: "Print one JSON object to stdout.")
    var json = false

    @OptionGroup
    var deviceOption: DeviceOption

    func validate() throws {
        do {
            _ = try AppBroadcastName.validate(action: action)
            if let receiver { _ = try AppBroadcastName.validate(receiver: receiver) }
        } catch let error as AppLifecycleError {
            throw ValidationError(error.message)
        }
    }

    func run() async throws {
        try AppManagementSupport.requireAndroid(deviceOption.id, command: "app broadcast")
        let route = try await DeviceRouter.routeForInput(deviceOption, logger: OffsiderLogger())
        let app = try AppTarget.resolve(appOption, route: route, command: "broadcast")
        let console = Console.current
        let sent = try await console.progress("Sending \(action)") {
            let backend = try await AppTarget.manager(route, app: app)
            try await route.backend.prepare()
            let id = try await route.backend.requireBootedDevice(route.device).id
            return try await backend.sendBroadcast(action, receiver: receiver, to: app, on: id)
        }
        await DeviceActivityLedger.current.recordInput(on: route.device)
        let result = sent.resultCode.map { "result \($0)" }
        let line = "Sent \(action) to \(app)" + (result.map { " (\($0))" } ?? "") + "."
        let notices: [Notice] = sent.receivers.isEmpty && receiver == nil
            ? [.note("No declared receiver takes this", agent: "No receiver in \(app)'s manifest takes \(action), so only one it registered while running could get it.")]
            : []
        DevicePersonView.emit(json ? AppManagementReport.broadcast(sent, on: route.device) : line, json: json, person: DevicePersonView.receipt("Sent \(action)", aside: result), notices: notices, console: console)
    }
}
