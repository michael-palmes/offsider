import ArgumentParser
import Foundation
import OffsiderCore

struct SleepCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sleep",
        abstract: "Turn a device's screen off, to limit burn-in; `offsider wake` turns it back on.",
        discussion: """
        Reads the screen first, so a screen already off stays off and nothing is sent. On an allowed iPhone or iPad it presses \
        the lock button through the runner, without needing an app in front. On an Android device it sends KEYCODE_SLEEP. \
        iOS simulators never sleep.

        A test device (`offsider devices add --test-device`) also sleeps by itself when its session goes idle or \
        `offsider session stop` ends it, and its next command wakes it.

        Examples:
          offsider sleep --device DEVICE_ID
        """
    )

    @Flag(name: .customLong("json"), help: "Print one JSON object to stdout.")
    var json = false

    @OptionGroup
    var deviceOption: DeviceOption

    func run() async throws {
        if case .iosSimulator = DeviceIDClassifier.classify(deviceOption.id) {
            throw CLIError(errorDescription: "sleep needs a phone, a tablet or an Android emulator: iOS simulators never sleep or lock.", reason: .notSupported)
        }
        let route = try await DeviceRouter.routeForInput(deviceOption, logger: OffsiderLogger())
        let console = Console.current
        let outcome = try await console.progress("Turning the screen off") {
            try await route.backend.prepare()
            guard let backend = route.backend as? any ScreenSleeping else {
                throw CLIError(errorDescription: "sleep is not available for \(route.device.rawValue).", reason: .notSupported)
            }
            return try await backend.sleepScreen(on: route.device)
        }
        let view = Self.view(outcome, device: route.device)
        DevicePersonView.emit(json ? view.json : view.text, json: json, person: DevicePersonView.receipt(view.person), console: console)
    }

    static func view(_ outcome: ScreenSleepOutcome, device: DeviceID) -> (text: String, json: String, person: String) {
        let json = DeviceStateReport.screen("sleep", on: device, previous: outcome.wasOn ? "on" : "off", current: "off", sent: outcome.sent ? ["sleep"] : [])
        return outcome.sent
            ? ("The screen of \(device.rawValue) is off.\n", json, "Screen off")
            : ("The screen of \(device.rawValue) is already off; nothing was sent.\n", json, "Screen already off")
    }
}
