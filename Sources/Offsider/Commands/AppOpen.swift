import ArgumentParser
import Foundation
import OffsiderCore

struct AppOpenCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "open",
        abstract: "Open a link in one app, as a deep link or universal link would.",
        discussion: """
        The link goes to the named app alone, never a browser: on Android `am start -W -a \
        android.intent.action.VIEW -d '<link>' <package>`, quoted whole so & and ? reach the app; on an iPhone or iPad \
        `devicectl device process launch --payload-url`, which the app receives as an open-URL call (not the \
        NSUserActivity a tapped universal link brings). A simulator opens it with `simctl openurl`, so iOS picks the \
        app that claims the link; Offsider taps Open on an `Open in` prompt only when it names the app, and checks the app \
        is in front afterwards. Quote the link in your \
        shell. Refused: spaces and control characters (percent-encode them), links over 4 KiB, and the intent:, \
        file:, content:, javascript: and data: schemes. On Android and a simulator, a link the app has no screen for, \
        or that lands on a chooser or another app, exits 1 with link_not_handled. On an iPhone or iPad exit 0 means \
        only that the link was delivered, as iOS does not say more, so `wait` for the screen. --restart stops the app \
        first, for a cold-start link; Android checks the link first, so a link it knows no screen for stops nothing.

        Example:
          offsider app open 'https://example.com/offer?id=7&ref=push' --app com.example.app --device DEVICE_ID
        """
    )

    @Argument(help: ArgumentHelp("The link, such as https://example.com/path or myapp://screen; quote it.", valueName: "link"))
    var url: String

    @OptionGroup
    var appOption: AppTargetOption

    @Flag(help: "Stop the app first, so the link opens it cold.")
    var restart = false

    @Flag(name: .customLong("json"), help: "Print one JSON object to stdout.")
    var json = false

    @OptionGroup
    var deviceOption: DeviceOption

    func validate() throws {
        do {
            _ = try AppLink.validate(url)
        } catch let error as AppLifecycleError {
            throw ValidationError(error.message)
        }
    }

    func run() async throws {
        let route = try await DeviceRouter.routeForInput(deviceOption, logger: OffsiderLogger())
        let app = try AppTarget.resolve(appOption, route: route, command: "open")
        let launch = try await Console.current.progress("Opening the link in \(app)") {
            let backend = try await AppTarget.backend(route, app: app)
            try await route.backend.prepare()
            let id = try await route.backend.requireBootedDevice(route.device).id
            return try await backend.openLink(url, in: app, restart: restart, on: id)
        }
        await DeviceActivityLedger.current.recordInput(on: route.device)
        let verb = Self.verb(launch)
        let text = json ? AppReport.launch(launch, action: "open", url: url, on: route.device) : AppTarget.launchLine(verb, launch)
        DevicePersonView.emit(text, json: json, person: DevicePersonView.receipt("\(verb) \(app)", aside: AppTarget.launchAside(launch)), console: .current)
        if launch.linkHandled == nil {
            Console.current.notice(.note("iOS does not say if a screen took the link. Check with `offsider describe-ui --device \(route.device.rawValue)`."))
        }
    }

    /// Says only what the platform showed: a delivered link is not an opened screen.
    static func verb(_ launch: AppLaunch) -> String {
        launch.linkHandled == nil ? "Sent the link to" : "Opened the link in"
    }
}
