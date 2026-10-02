import ArgumentParser
import Foundation
import OffsiderCore

struct AppearanceCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "appearance",
        abstract: "Read or set the system appearance (light or dark).",
        discussion: """
        Without a value, prints the current appearance. On Android this is night mode (`cmd uimode night`).

        Examples:
          offsider appearance --device DEVICE_ID
          offsider appearance dark --device DEVICE_ID
        """
    )

    @Argument(help: ArgumentHelp("light or dark; omit to read the current appearance.", valueName: "light|dark"))
    var value: String?

    @Flag(name: .customLong("json"), help: "Print one JSON object to stdout.")
    var json = false

    @OptionGroup
    var deviceOption: DeviceOption

    func validate() throws {
        _ = try target()
    }

    func target() throws -> Appearance? {
        guard let value else { return nil }
        guard let appearance = Appearance(rawValue: value.trimmingCharacters(in: .whitespaces).lowercased()) else {
            throw ValidationError("Unknown appearance '\(value)'. Use light or dark.")
        }
        return appearance
    }

    func run() async throws {
        let target = try target()
        let logger = OffsiderLogger()
        let route = try await DeviceRouter.route(deviceOption.id, logger: logger)
        try await route.backend.prepare()
        let device = try await route.backend.requireBootedDevice(route.device).id
        guard let settings = route.backend as? any DeviceSettingsControlling else {
            throw CLIError(errorDescription: "appearance is not available for \(deviceOption.id).")
        }

        let current = try await settings.appearance(on: device)
        guard let target else {
            print(json ? DeviceSettingsReport.appearance(current, previous: nil) : "Appearance: \(current.rawValue)")
            return
        }
        if target != current {
            try await settings.setAppearance(target, on: device)
        }
        print(json ? DeviceSettingsReport.appearance(target, previous: current) : Self.line(target, previous: current))
    }

    static func line(_ current: Appearance, previous: Appearance?) -> String {
        guard let previous, previous != current else { return "Appearance: \(current.rawValue)" }
        return "Appearance: \(current.rawValue) (was \(previous.rawValue))"
    }
}
