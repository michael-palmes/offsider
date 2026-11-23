import ArgumentParser
import Foundation
import OffsiderCore

struct ScreenReaderCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "screen-reader",
        abstract: "Turn an iOS simulator's screen reader on or off, or read it.",
        discussion: """
        Without a value, prints the setting. `on` tells every app on the simulator that VoiceOver is running, so an app \
        that changes its screen for a screen reader does. A simulator never starts VoiceOver itself: nothing is spoken, \
        and tap, swipe and every other input work as they always do. The setting outlives the command and a reboot, so \
        `session stop` and `shutdown` turn it off again, only if this command turned it on. Set by hand first, it stays \
        as it was. iOS simulators only: an iPhone, iPad or Android device is refused, with nothing sent.

        Examples:
          offsider screen-reader on --device DEVICE_ID
          offsider screen-reader --device DEVICE_ID --json
          offsider screen-reader off --device DEVICE_ID
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

    /// Before routing, so a phone, iPhone or iPad is refused without starting its stack.
    static func requireSimulator(_ id: String) throws {
        switch DeviceIDClassifier.classify(id) {
        case .iosDevice:
            throw CLIError(errorDescription: "screen-reader runs on iOS simulators only, and \(id) is a physical iPhone or iPad. Nothing was sent.", reason: .notSupported)
        case .androidSerial, .androidNetworkSerial:
            throw CLIError(errorDescription: "screen-reader runs on iOS simulators only, and \(id) is an Android device. Nothing was sent.", reason: .notSupported)
        case .androidName:
            throw CLIError(errorDescription: "screen-reader runs on iOS simulators only, by UDID, and \(id) is not one. Nothing was sent.", reason: .notSupported, hint: "offsider devices")
        case .iosSimulator, .empty, .unrecognised:
            break
        }
    }

    func run() async throws {
        let target = try target()
        try Self.requireSimulator(deviceOption.id)
        let route = try await DeviceRouter.routeForInput(deviceOption, logger: OffsiderLogger(), locking: target != nil)
        let console = Console.current
        let (change, id): (ScreenReaderChange, DeviceID) = try await console.progress(target.map { "Turning the screen reader \($0 ? "on" : "off")" } ?? "Reading the screen reader") {
            try await route.backend.prepare()
            let id = try await route.backend.requireBootedDevice(route.device).id
            guard let backend = route.backend as? any ScreenReaderControlling else {
                throw CLIError(errorDescription: "screen-reader is not available for \(id.rawValue).", reason: .notSupported)
            }
            if let target { return (try await backend.setScreenReader(target, on: id), id) }
            let current = try await backend.screenReader(on: id)
            return (ScreenReaderChange(previous: current, current: current, resetBySessionStop: current && ScreenReaderRecordStore.privateStore(create: false)?.load(udid: id.rawValue) != nil), id)
        }
        if target != nil { await DeviceActivityLedger.current.recordInput(on: route.device) }
        let word = change.current ? "on" : "off"
        let was = target == nil ? nil : DevicePersonView.change(from: change.previous ? "on" : "off", to: word)
        let text = json
            ? DeviceStateReport.screenReader(target == nil ? "show" : word, current: change.current, previous: target == nil ? nil : change.previous, service: SimulatorScreenReader.service, resetBySessionStop: change.resetBySessionStop, on: id)
            : "Screen reader: \(word)" + (was.map { " (\($0))" } ?? "") + "."
        let person = target == nil ? DevicePersonView.reading("Screen reader", word, detail: SimulatorScreenReader.service) : DevicePersonView.receipt("Screen reader \(word)", aside: was)
        DevicePersonView.emit(text, json: json, person: person, notices: Self.notices(change, set: target != nil, on: id), console: console)
    }

    /// Who undoes it, and that a simulator's input is unchanged: this session's stop when Offsider turned it on, else the person who did.
    static func notices(_ change: ScreenReaderChange, set: Bool, on id: DeviceID) -> [Notice] {
        guard set, change.current else { return [] }
        let undo = "offsider session stop --device \(id.rawValue)"
        return change.resetBySessionStop
            ? [DevicePersonView.lasting("Apps see VoiceOver on until session stop", undo: undo, agent: "Note: apps on \(id.rawValue) are told VoiceOver is on, across reboots, until `\(undo)` turns it off. A simulator runs no VoiceOver, so input works as usual.")]
            : [.note("It was already on, so session stop leaves it", agent: "The screen reader was already on for \(id.rawValue), so session stop leaves it on.")]
    }
}
