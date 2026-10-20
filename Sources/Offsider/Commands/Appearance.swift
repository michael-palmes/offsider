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
        let route = try await DeviceRouter.routeForInput(deviceOption, logger: logger, locking: target != nil)
        let console = Console.current
        let (text, person) = try await console.progress(target.map { "Switching to \($0.rawValue)" } ?? "Reading the appearance") {
            try await route.backend.prepare()
            let device = try await route.backend.requireBootedDevice(route.device).id
            guard let settings = route.backend as? any DeviceSettingsControlling else {
                throw CLIError(errorDescription: "appearance is not available for \(deviceOption.id).", reason: .notSupported)
            }
            let result = try await Self.apply(target, on: device, settings: settings)
            let person = target.map { DevicePersonView.appearanceSet($0, before: result.before) } ?? DevicePersonView.appearance(result.current)
            return (Self.text(result, target: target, json: json), person)
        }
        DevicePersonView.emit(text, json: json, person: person, console: console)
    }

    /// What the device read before and after; `before` is nil when reading only, or when the read failed.
    struct Result {
        let current: AppearanceReading
        let before: AppearanceReading?
    }

    /// Reads, or sets `target`; when setting, a previous value that is not light or dark is unknown rather than an error.
    @MainActor
    static func report(_ target: Appearance?, json: Bool, on device: DeviceID, settings: any DeviceSettingsControlling) async throws -> String {
        text(try await apply(target, on: device, settings: settings), target: target, json: json)
    }

    @MainActor
    static func apply(_ target: Appearance?, on device: DeviceID, settings: any DeviceSettingsControlling) async throws -> Result {
        guard let target else { return Result(current: try await settings.appearance(on: device), before: nil) }
        let before = try? await settings.appearance(on: device)
        if target != before?.appearance {
            try await settings.setAppearance(target, on: device)
        }
        return Result(current: .fixed(target), before: before)
    }

    static func text(_ result: Result, target: Appearance?, json: Bool) -> String {
        let previous = result.before?.appearance
        guard let target else { return json ? DeviceSettingsReport.appearance(result.current, previous: nil) : line(result.current) }
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
