import ArgumentParser
import Darwin
import Foundation
import OffsiderAndroid
import OffsiderCore

struct UnlockCodeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "unlock-code",
        abstract: "Save, check or remove the lock screen PIN or password `wake --unlock` types on an Android device.",
        discussion: """
        The code is kept in your login Keychain under the phone's serial or the AVD's name, never in a file, an \
        argument or Offsider's output. `set` asks for it twice, showing a dot for each character, or reads one line with --stdin: \
        4 to 64 printable ASCII characters (a PIN is 4 to 16 digits). Save codes only for test devices: anything \
        that can run commands as you can then unlock them. A connected phone is named by its maker and model, read \
        with one `getprop`; nothing else is sent to the device.

        Examples:
          offsider unlock-code set --device PHONE_SERIAL
          op read op://Devices/phone/code | offsider unlock-code set --stdin --device PHONE_SERIAL
          offsider unlock-code status --device PHONE_SERIAL
          offsider unlock-code remove --device PHONE_SERIAL
        """
    )

    enum Action: String, CaseIterable {
        case set
        case status
        case remove
    }

    @Argument(help: ArgumentHelp("set, status or remove.", valueName: "action"))
    var action: String

    @Flag(name: .customLong("stdin"), help: "With set: read the code from the first line of standard input instead of asking.")
    var stdin = false

    @Flag(name: .customLong("json"), help: "Print one JSON object to stdout.")
    var json = false

    @OptionGroup
    var deviceOption: ReadDeviceOption

    func validate() throws {
        let parsed = try parsedAction()
        if stdin, parsed != .set { throw ValidationError("--stdin goes with set, not \(parsed.rawValue).") }
    }

    func parsedAction() throws -> Action {
        guard let parsed = Action(rawValue: action.trimmingCharacters(in: .whitespaces).lowercased()) else {
            throw ValidationError("Unknown action '\(action)'. Use set, status or remove.")
        }
        return parsed
    }

    func run() async throws {
        let parsed = try parsedAction()
        let device = try Self.deviceKey(deviceOption.id)
        let name = DeviceName.display(device, label: await AndroidPhoneLabel.label(serial: device, host: .cli()))
        let styled: TerminalStyle? = json || isatty(STDOUT_FILENO) == 0 ? nil : .detect(isTerminal: true)
        let store = KeychainUnlockCodeStore()
        guard parsed == .set, !stdin, isatty(STDIN_FILENO) != 0 else {
            let readCode: () throws -> UnlockCode = stdin ? Self.readFromStandardInput : {
                throw CLIError(errorDescription: "unlock-code set asks for the code on a terminal; without one, pass --stdin and pipe the code in.", reason: .usage)
            }
            print(try Self.perform(parsed, device: device, name: name, json: json, styled: styled, store: store, ledger: UnlockAttemptLedger(), readCode: readCode))
            return
        }
        print(try TerminalPrompt.run(cancelled: PromptScreen.cancelledNothingSaved) { prompt in
            try Self.perform(.set, device: device, name: name, json: json, styled: styled, store: store, ledger: UnlockAttemptLedger()) {
                try Self.ask(prompt, name: name)
            }
        })
    }

    /// A phone serial or an AVD name; emulator serials change between launches, so they are refused.
    static func deviceKey(_ raw: String) throws -> String {
        let id = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        switch DeviceIDClassifier.classify(id) {
        case .androidName(let name):
            return name
        case .androidSerial:
            throw CLIError(errorDescription: "Save an emulator's code under its AVD name from `offsider list-devices`: \(id) changes from launch to launch.", reason: .usage, hint: "offsider list-devices")
        case .androidNetworkSerial(let serial):
            throw AndroidError.networkDevice(serial)
        case .iosSimulator:
            throw CLIError(errorDescription: "unlock-code is Android only: iOS simulators have no lock screen code.", reason: .notSupported)
        case .iosDevice:
            throw CLIError(errorDescription: "unlock-code is Android only: Offsider never stores or types an iPhone or iPad passcode. Unlock it by hand.", reason: .notSupported)
        case .empty, .unrecognised:
            throw CLIError(errorDescription: "\(id.isEmpty ? "Device ID cannot be empty" : "\(id) is not a phone serial or AVD name"). Run `offsider list-devices` to find device IDs.", reason: .invalidDeviceID, hint: "offsider list-devices")
        }
    }

    /// `device` is the Keychain key and goes in JSON; `name` is for people.
    static func perform(_ action: Action, device: String, name: String? = nil, json: Bool, styled: TerminalStyle? = nil, store: any UnlockCodeStoring, ledger: UnlockAttemptLedger, readCode: () throws -> UnlockCode) throws -> String {
        let name = name ?? device
        switch action {
        case .set:
            try store.save(try readCode(), for: device)
            ledger.clear(device)
            if json { return report("set", device: device, saved: true, lastAttemptFailed: false) }
            if let styled { return UnlockCodeScreen.saved(name: name, device: device, style: styled) }
            return "Saved the unlock code for \(name) in the login Keychain. `offsider wake --unlock --device \(device)` types it when the lock screen asks."
        case .status:
            let saved = try store.hasCode(for: device)
            let failed = ledger.hasFailed(device)
            if json { return report("status", device: device, saved: saved, lastAttemptFailed: failed) }
            if let styled { return UnlockCodeScreen.status(name: name, device: device, saved: saved, lastAttemptFailed: failed, style: styled) }
            guard saved else { return "\(name): no unlock code saved" }
            return failed
                ? "\(name): unlock code saved, but it did not unlock the device last time, so Offsider will not type it until the device is unlocked by hand or the code is saved again"
                : "\(name): unlock code saved"
        case .remove:
            let removed = try store.remove(for: device)
            ledger.clear(device)
            if json { return report("remove", device: device, saved: false, lastAttemptFailed: false) }
            if let styled { return UnlockCodeScreen.removed(name: name, removed: removed, style: styled) }
            return removed ? "Removed the unlock code for \(name)" : "No unlock code was saved for \(name)"
        }
    }

    static func report(_ action: String, device: String, saved: Bool, lastAttemptFailed: Bool) -> String {
        DeviceStateReport.unlockCode(action, device: device, saved: saved, lastAttemptFailed: lastAttemptFailed)
    }

    static let formatMessage = "A code is 4 to 64 printable ASCII characters (a PIN is 4 to 16 digits)."

    static func readFromStandardInput() throws -> UnlockCode {
        guard let line = readLine(strippingNewline: true), let code = UnlockCode(line) else {
            throw CLIError(errorDescription: "The first line of standard input must be the code. \(formatMessage)", reason: .usage)
        }
        return code
    }

    /// Asks twice on the terminal, showing a dot for each character.
    static func ask(_ prompt: TerminalPrompt, name: String) throws -> UnlockCode {
        prompt.lines(UnlockCodeScreen.header(name: name, style: prompt.style))
        let labels = PromptScreen.labels([UnlockCodeScreen.codeLabel, UnlockCodeScreen.againLabel])
        let text = try prompt.askSecret(labels[0], again: labels[1], check: UnlockCodeScreen.codeProblem)
        guard let code = UnlockCode(text) else { throw CLIError(errorDescription: "\(formatMessage) Nothing was saved.", reason: .usage) }
        return code
    }
}
