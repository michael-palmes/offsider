import ArgumentParser
import Foundation
import OffsiderCore

struct ScreenReaderCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "screen-reader",
        abstract: "Turn the screen reader on or off, or read it, on a simulator, an emulator or a test device.",
        discussion: """
        Without a value, prints the setting. The setting outlives the command and a reboot, so `session stop` and \
        `shutdown` turn it off again, only if this command turned it on. Set by hand first, it stays as it was.

        An iOS simulator: `on` tells every app that VoiceOver is running, so an app that changes its screen for a \
        screen reader does. A simulator never starts VoiceOver itself: nothing is spoken, and every input works as usual.

        An Android emulator or test device: `on` starts TalkBack. Offsider's input still reaches the app as it always \
        does: tap, swipe, type and the rest act directly, never through TalkBack's selection, so nothing here tests \
        TalkBack's own gestures. An emulator must have been started without sound, as `offsider boot` starts it. \
        TalkBack speaks on a test device itself.

        Refused, with nothing sent: an iPhone or iPad, and an Android phone that is not a test device.

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

    /// Before routing, so an iPhone, iPad or a phone in personal use is refused without starting its stack.
    static func requireSupported(_ id: String, gate: DevicePolicyGate = .current) throws {
        switch DeviceIDClassifier.classify(id) {
        case .iosDevice:
            throw CLIError(errorDescription: "screen-reader does not reach an iPhone or iPad, and \(id) is one. Nothing was sent.", reason: .notSupported)
        case .androidNetworkSerial:
            throw CLIError(errorDescription: "screen-reader runs on simulators, emulators and USB test devices, and \(id) is a network adb connection. Nothing was sent.", reason: .notSupported)
        case .androidName(let serial):
            let policy = gate.policy()
            guard let allowance = policy.list.entry(platform: .android, key: serial) else { return }
            try requireTestDevice(allowance, device: serial, policy: policy)
        case .iosSimulator, .androidSerial, .empty, .unrecognised:
            break
        }
    }

    /// A screen reader changes what its owner's own touches do and stays on after the cable is pulled, so only a device a person set aside for testing gets one.
    static func requireTestDevice(_ allowance: DeviceAllowance, device: String, policy: PhysicalDevicePolicy) throws {
        guard !policy.drivesWhole(allowance) else { return }
        if let off = policy.testDeviceOff(allowance) {
            throw CLIError(errorDescription: "\(device) is a test device, but \(off), so Offsider left its screen reader alone. Nothing was sent. Ask the administrator of this Mac.", reason: .notSupported)
        }
        throw CLIError(
            errorDescription: "\(device) is in personal use, not a test device, and Offsider changes the screen reader only on a simulator, an emulator or a test device. Nothing was sent.",
            reason: .notSupported, hint: "offsider devices status"
        )
    }

    func run() async throws {
        let target = try target()
        try Self.requireSupported(deviceOption.id)
        let route = try await DeviceRouter.routeForInput(deviceOption, logger: OffsiderLogger(), locking: target != nil)
        if let allowance = route.allowance {
            try Self.requireTestDevice(allowance, device: route.device.rawValue, policy: DevicePolicyGate.current.policy())
        }
        let console = Console.current
        let (change, id, service): (ScreenReaderChange, DeviceID, String) = try await console.progress(target.map { "Turning the screen reader \($0 ? "on" : "off")" } ?? "Reading the screen reader") {
            try await route.backend.prepare()
            let id = try await route.backend.requireBootedDevice(route.device).id
            guard let backend = route.backend as? any ScreenReaderControlling else {
                throw CLIError(errorDescription: "screen-reader is not available for \(id.rawValue).", reason: .notSupported)
            }
            let service = await backend.screenReaderService
            if let target { return (try await backend.setScreenReader(target, on: id), id, service) }
            let current = try await backend.screenReader(on: id)
            let recorded = await backend.screenReaderIsRecorded(on: id)
            return (ScreenReaderChange(previous: current, current: current, resetBySessionStop: current && recorded), id, service)
        }
        if target != nil { await DeviceActivityLedger.current.recordInput(on: route.device) }
        let word = change.current ? "on" : "off"
        let was = target == nil ? nil : DevicePersonView.change(from: change.previous ? "on" : "off", to: word)
        let text = json
            ? DeviceStateReport.screenReader(target == nil ? "show" : word, current: change.current, previous: target == nil ? nil : change.previous, service: service, resetBySessionStop: change.resetBySessionStop, on: id)
            : "Screen reader: \(word)" + (was.map { " (\($0))" } ?? "") + "."
        let person = target == nil ? DevicePersonView.reading("Screen reader", word, detail: service) : DevicePersonView.receipt("Screen reader \(word)", aside: was)
        DevicePersonView.emit(text, json: json, person: person, notices: Self.notices(change, set: target != nil, on: id), console: console)
    }

    /// Who undoes it, and that input still acts as usual: a simulator runs no VoiceOver, and on Android Offsider's touches go past TalkBack.
    static func notices(_ change: ScreenReaderChange, set: Bool, on id: DeviceID) -> [Notice] {
        guard set, change.current else { return [] }
        let undo = "offsider session stop --device \(id.rawValue)"
        let android = id.platform == .android
        guard change.resetBySessionStop else {
            return [.note("It was already on, so session stop leaves it", agent: "The screen reader was already on for \(id.rawValue), so session stop leaves it on.")]
        }
        let agent = android
            ? "Note: TalkBack is on for \(id.rawValue), across reboots, until `\(undo)` turns it off. Offsider's input goes past TalkBack, so tap, swipe and the rest work as usual."
            : "Note: apps on \(id.rawValue) are told VoiceOver is on, across reboots, until `\(undo)` turns it off. A simulator runs no VoiceOver, so input works as usual."
        return [DevicePersonView.lasting(android ? "TalkBack stays on until session stop" : "Apps see VoiceOver on until session stop", undo: undo, agent: agent)]
    }
}
