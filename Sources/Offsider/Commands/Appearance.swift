import ArgumentParser
import Foundation
import OffsiderCore

struct AppearanceCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "appearance",
        abstract: "Read or set the system appearance (light or dark).",
        discussion: """
        Without a value, prints the current appearance. On Android this is night mode (`cmd uimode night`), \
        which can also read auto or custom when it follows a schedule; setting light or dark replaces that \
        schedule, and the result then shows no previous value.

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

        print(try await Self.report(target, json: json, on: device, settings: settings))
    }

    /// Reads, or sets `target`; when setting, a previous value that is not light or dark is unknown rather than an error.
    @MainActor
    static func report(_ target: Appearance?, json: Bool, on device: DeviceID, settings: any DeviceSettingsControlling) async throws -> String {
        guard let target else {
            let current = try await settings.appearance(on: device)
            return json ? DeviceSettingsReport.appearance(current, previous: nil) : line(current)
        }
        let previous = (try? await settings.appearance(on: device))?.appearance
        if target != previous {
            try await settings.setAppearance(target, on: device)
        }
        return json ? DeviceSettingsReport.appearance(target, previous: previous) : line(target, previous: previous)
    }

    static func line(_ reading: AppearanceReading) -> String {
        switch reading {
        case .fixed(let appearance): return line(appearance, previous: nil)
        case .scheduled("auto"): return "Appearance: auto (follows the system schedule)"
        case .scheduled(let mode): return "Appearance: \(mode) (follows a custom schedule)"
        }
    }

    static func line(_ current: Appearance, previous: Appearance?) -> String {
        guard let previous, previous != current else { return "Appearance: \(current.rawValue)" }
        return "Appearance: \(current.rawValue) (was \(previous.rawValue))"
    }
}
