import ArgumentParser
import Foundation
import OffsiderCore

struct AirplaneCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "airplane",
        abstract: "Turn an Android device's airplane mode on or off, or read it.",
        discussion: """
        Without a value, prints the setting. `on` runs `cmd connectivity airplane-mode enable` and checks it took, which \
        needs Android 11. It outlives the command and a reboot, so `session stop --device` turns it off again, only if this \
        command turned it on. Set by hand first, it stays as it was. USB stays connected; an emulator also loses its \
        route to the Mac's Metro at 10.0.2.2. Android only.

        Examples:
          offsider airplane on --device DEVICE_ID
          offsider airplane --device DEVICE_ID
          offsider airplane off --device DEVICE_ID
        """
    )

    @Argument(help: ArgumentHelp("on or off; omit to read the setting.", valueName: "on|off"))
    var value: String?

    @Flag(name: .customLong("json"), help: "Print one JSON object to stdout.")
    var json = false

    @OptionGroup
    var deviceOption: DeviceOption

    func validate() throws {
        _ = try target()
    }

    func target() throws -> Bool? {
        guard let value else { return nil }
        switch value.trimmingCharacters(in: .whitespaces).lowercased() {
        case "on": return true
        case "off": return false
        default: throw ValidationError("Unknown value '\(value)'. Use on or off.")
        }
    }

    func run() async throws {
        let target = try target()
        try StayAwakeCommand.requireAndroid(deviceOption.id, command: "airplane")
        let route = try await DeviceRouter.routeForInput(deviceOption, logger: OffsiderLogger(), locking: target != nil)
        let console = Console.current
        let (change, id): (AirplaneChange, DeviceID) = try await console.progress(target.map { "Turning airplane mode \($0 ? "on" : "off")" } ?? "Reading airplane mode") {
            try await route.backend.prepare()
            let id = try await route.backend.requireBootedDevice(route.device).id
            guard let backend = route.backend as? any AirplaneControlling else {
                throw CLIError(errorDescription: "airplane is not available for \(id.rawValue).", reason: .notSupported)
            }
            if let target { return (try await backend.setAirplaneMode(target, on: id), id) }
            let current = try await backend.airplaneMode(on: id)
            return (AirplaneChange(previous: current, current: current, resetBySessionStop: false), id)
        }
        if target != nil { await DeviceActivityLedger.current.recordInput(on: route.device) }
        let word = change.current ? "on" : "off"
        let was = target == nil ? nil : DevicePersonView.change(from: change.previous ? "on" : "off", to: word)
        let text = json
            ? AppManagementReport.airplane(target == nil ? "show" : word, current: change.current, previous: target == nil ? nil : change.previous, resetBySessionStop: change.resetBySessionStop, on: id)
            : "Airplane mode: \(word)" + (was.map { " (\($0))" } ?? "") + "."
        let person = target == nil ? DevicePersonView.reading("Airplane mode", word) : DevicePersonView.receipt("Airplane mode \(word)", aside: was)
        DevicePersonView.emit(text, json: json, person: person, notices: Self.notices(change, set: target != nil, on: id), console: console)
    }

    /// Who undoes it: this session's stop when Offsider turned it on, else the person who did.
    static func notices(_ change: AirplaneChange, set: Bool, on id: DeviceID) -> [Notice] {
        guard set, change.current else { return [] }
        let undo = "offsider session stop --device \(id.rawValue)"
        return change.resetBySessionStop
            ? [DevicePersonView.lasting("Stays on until session stop", undo: undo, agent: "Note: airplane mode stays on for \(id.rawValue), across reboots, until `\(undo)` turns it off.")]
            : [.note("It was already on, so session stop leaves it", agent: "Airplane mode was already on for \(id.rawValue), so session stop leaves it on.")]
    }
}
