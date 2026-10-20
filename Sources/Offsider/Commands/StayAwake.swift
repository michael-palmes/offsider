import ArgumentParser
import Foundation
import OffsiderCore

struct StayAwakeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "stay-awake",
        abstract: "Keep an Android device's screen on while it charges, or read the setting.",
        discussion: """
        Without a value, prints the setting and the screen timeout. `on` sets Developer options > Stay awake for every \
        power source (the `stay_on_while_plugged_in` global setting) and `off` clears it; the setting outlives the command and reboots. It \
        works only while the device charges, which a phone on USB and an emulator do, and it keeps an awake screen \
        on: `offsider wake` turns a sleeping one on. Android only: iOS simulators never sleep.

        Examples:
          offsider stay-awake --device DEVICE_ID
          offsider stay-awake on --device DEVICE_ID
          offsider stay-awake off --device DEVICE_ID
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
        try Self.requireAndroid(deviceOption.id, command: "stay-awake")
        let route = try await DeviceRouter.routeForInput(deviceOption, logger: OffsiderLogger(), locking: target != nil)
        let console = Console.current
        let (result, id) = try await console.progress(target.map { "Turning stay awake \($0 ? "on" : "off")" } ?? "Reading stay awake") {
            try await route.backend.prepare()
            let booted = try await route.backend.requireBootedDevice(route.device)
            guard let backend = route.backend as? any AwakeControlling else {
                throw CLIError(errorDescription: "stay-awake is not available for \(booted.id.rawValue).", reason: .notSupported)
            }
            return (try await Self.result(target, json: json, booted: booted, backend: backend), booted.id)
        }
        DevicePersonView.emit(result.text, json: json, person: result.person, notices: Self.notices(target, on: id), console: console)
    }

    /// After turning it on, how a person turns it off; an agent reads only the phone's note, as it always did.
    static func notices(_ target: Bool?, on device: DeviceID) -> [Notice] {
        guard target == true else { return [] }
        let undo = "offsider stay-awake off --device \(device.rawValue)"
        return [DevicePersonView.lasting("Stays on across reboots", undo: undo, agent: phoneNote(target, on: device))]
    }

    /// One stderr line after turning stay awake on for a USB phone: the setting outlives the command and reboots.
    static func phoneNote(_ target: Bool?, on device: DeviceID) -> String? {
        guard target == true, device.isPhysicalAndroidDevice else { return nil }
        return "Note: stay awake stays on for \(device.rawValue), across reboots; `offsider stay-awake off --device \(device.rawValue)` turns it off."
    }

    /// Before routing, so a simulator is refused without starting its stack.
    static func requireAndroid(_ id: String, command: String) throws {
        switch DeviceIDClassifier.classify(id) {
        case .iosSimulator:
            throw CLIError(errorDescription: "\(command) is Android only: iOS simulators never sleep or lock.", reason: .notSupported)
        case .iosDevice:
            throw CLIError(errorDescription: "\(command) is Android only: on an iPhone or iPad, set Auto-Lock in Settings and unlock it by hand.", reason: .notSupported)
        default:
            break
        }
    }

    @MainActor
    static func report(_ target: Bool?, json: Bool, booted: BootedDevice, backend: any AwakeControlling) async throws -> String {
        try await result(target, json: json, booted: booted, backend: backend).text
    }

    /// The agent's text or JSON, and what a person sees.
    @MainActor
    static func result(_ target: Bool?, json: Bool, booted: BootedDevice, backend: any AwakeControlling) async throws -> (text: String, person: [Block]) {
        let device = booted.id
        guard let target else {
            let reading = try await backend.awakeState(on: device)
            let person = DevicePersonView.stayAwake(reading, previous: nil, setting: false)
            if json { return (DeviceStateReport.stayAwake("show", current: reading, previous: nil, on: device), person) }
            return (line(reading, previous: nil, name: DeviceName.android(serial: device.rawValue, listed: booted.name, maker: reading.maker)), person)
        }
        let (previous, current) = try await backend.setStayAwake(target, on: device)
        let person = DevicePersonView.stayAwake(current, previous: previous, setting: true)
        if json { return (DeviceStateReport.stayAwake(target ? "on" : "off", current: current, previous: previous, on: device), person) }
        return (line(current, previous: previous, name: DeviceName.android(serial: device.rawValue, listed: booted.name, maker: current.maker)), person)
    }

    /// `Motorola moto g (ZY22FAKE01): stay awake on while charging (was off)`, with the reason when it has no effect.
    static func line(_ reading: AwakeReading, previous: AwakeReading?, name: String) -> String {
        let on = !reading.stayAwake.isEmpty
        let was = previous.map { !$0.stayAwake.isEmpty } == !on ? "was \(on ? "off" : "on")" : nil
        let timeout = reading.screenTimeoutSummary.map { "after \($0)" } ?? "when it times out"
        guard on else {
            let notes = [was, reading.screenTimeoutSummary.map { "screen timeout \($0)" }].compactMap { $0 }
            return "\(name): stay awake off" + (notes.isEmpty ? "" : " (\(notes.joined(separator: ", ")))")
        }
        let everySource = reading.stayAwake.isSuperset(of: [.ac, .usb, .wireless])
        let head = "\(name): stay awake on while charging\(everySource ? "" : " over \(reading.stayAwake.summary)")\(was.map { " (\($0))" } ?? "")"
        if reading.timeoutCappedByPolicy {
            return "\(head), but a device policy limits the screen timeout, so Android ignores it"
        }
        if !reading.staysAwake, reading.screenTimeoutSummary == "never" {
            return "\(head); the screen timeout is never, so the screen stays on anyway"
        }
        if reading.charging.isEmpty {
            return "\(head), but it is not charging, so the screen still turns off \(timeout)"
        }
        if !reading.staysAwake {
            return "\(head), but it charges over \(reading.charging.summary), so the screen still turns off \(timeout)"
        }
        return head
    }
}
