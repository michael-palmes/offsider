import ArgumentParser
import Foundation
import OffsiderCore

struct Wake: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Turn an Android device's screen on and dismiss its lock screen.",
        discussion: """
        Sends nothing when the screen is already on and unlocked. Otherwise it presses the wake key, dismisses the \
        lock screen and waits about 3 s. A PIN, pattern or password lock screen stays up, and the command exits 7 \
        (device_locked) unless --unlock finds a PIN or password saved with `offsider unlock-code set`. Then it types \
        that code once, and only into the lock screen's own focused PIN or password field. If the code does not \
        unlock the device, Offsider will not type it again until the device is unlocked by hand or the code is saved \
        again. Patterns are not supported. Android only: iOS simulators never sleep.

        Examples:
          offsider wake --device DEVICE_ID
          offsider wake --unlock --device PHONE_SERIAL
        """
    )

    @Flag(name: .customLong("unlock"), help: "Type the PIN or password saved with `offsider unlock-code set` when the lock screen stays up.")
    var unlock = false

    @Flag(name: .customLong("json"), help: "Print one JSON object to stdout.")
    var json = false

    @OptionGroup
    var deviceOption: DeviceOption

    func run() async throws {
        try StayAwakeCommand.requireAndroid(deviceOption.id, command: "wake")
        let route = try await DeviceRouter.routeForInput(deviceOption, logger: OffsiderLogger())
        try await route.backend.prepare()
        let booted = try await route.backend.requireBootedDevice(route.device)
        guard let backend = route.backend as? any AwakeControlling else {
            throw CLIError(errorDescription: "wake is not available for \(booted.id.rawValue).", reason: .notSupported)
        }
        print(try await Self.report(
            unlock: unlock, json: json, booted: booted,
            backend: backend, store: KeychainUnlockCodeStore(), ledger: UnlockAttemptLedger()
        ))
    }

    /// A phone's serial, or an emulator's AVD name; nil when the AVD name is unknown.
    static func unlockKey(_ booted: BootedDevice) -> String? {
        guard case .androidSerial = DeviceIDClassifier.classify(booted.id.rawValue) else { return booted.id.rawValue }
        return booted.name == booted.id.rawValue ? nil : booted.name
    }

    /// Messages name the device for people; the commands in them keep the serial, so they still run.
    @MainActor
    static func report(
        unlock: Bool,
        json: Bool,
        booted: BootedDevice,
        backend: any AwakeControlling,
        store: any UnlockCodeStoring,
        ledger: UnlockAttemptLedger
    ) async throws -> String {
        let device = booted.id
        let serial = device.rawValue
        let outcome = try await backend.wake(on: device)
        let name = DeviceName.android(serial: serial, listed: booted.name, maker: outcome.previous.maker)
        var current = outcome.current
        var sent = outcome.sent
        guard current.screen == .on else {
            throw CLIError(errorDescription: "The screen of \(name) did not turn on within about 3 s. Check the device, then retry.", reason: .stateNotReached)
        }
        let unlockKey = Self.unlockKey(booted)
        if current.lockScreen == .secure {
            guard unlock else {
                throw CLIError(
                    errorDescription: "The screen of \(name) is on, but its \(current.credentialName) lock screen is showing. Unlock it on the device, or save its code with `offsider unlock-code set` and run `offsider wake --unlock --device \(serial)`.",
                    reason: .deviceLocked,
                    hint: "offsider wake --unlock --device \(serial)"
                )
            }
            current = try await enterSavedCode(current, on: device, name: name, key: unlockKey, backend: backend, store: store, ledger: ledger)
            sent.append("code")
        }
        if current.lockScreen == .swipe {
            throw CLIError(errorDescription: "The lock screen of \(name) stayed up after `wm dismiss-keyguard`. Swipe it away on the device.", reason: .deviceLocked)
        }
        if let unlockKey { ledger.clear(unlockKey) }
        let result = WakeOutcome(previous: outcome.previous, current: current, sent: sent)
        return json ? DeviceStateReport.wake(result, on: device) : line(result, name: name)
    }

    /// One attempt; a rejected code is recorded so no later command types it again.
    @MainActor
    static func enterSavedCode(
        _ reading: AwakeReading,
        on device: DeviceID,
        name: String,
        key: String?,
        backend: any AwakeControlling,
        store: any UnlockCodeStoring,
        ledger: UnlockAttemptLedger
    ) async throws -> AwakeReading {
        func locked(_ message: String, hint: String? = nil) -> CLIError {
            CLIError(errorDescription: message, reason: .deviceLocked, hint: hint)
        }
        guard let key else {
            throw locked("Offsider could not read the AVD name of \(name), which its saved code is kept under. Unlock it on the device.")
        }
        let save = "offsider unlock-code set --device \(key)"
        if reading.credential == "pattern" {
            throw locked("\(name) has a pattern lock screen, and Offsider types only PINs and passwords. Unlock it on the device.")
        }
        guard !ledger.hasFailed(key) else {
            throw locked("The saved code did not unlock \(name) last time, so Offsider will not type it again. Unlock it on the device, or save the right code with `\(save)`.", hint: save)
        }
        guard let code = try store.code(for: key) else {
            throw locked("No unlock code is saved for \(name). Unlock it on the device, or save one with `\(save)`.", hint: save)
        }
        if reading.credential == "pin", !code.isPIN {
            throw locked("\(name) asks for a PIN, but its saved code is not 4 to 16 digits, so Offsider typed nothing. Save its PIN with `\(save)`.", hint: save)
        }
        let after: AwakeReading
        do {
            after = try await backend.enterUnlockCode(code, on: device)
        } catch let failure as any OffsiderFailure where failure.reason == .deviceLocked {
            throw locked("The lock screen of \(name) showed no PIN or password field, so Offsider typed nothing. Unlock it on the device.")
        }
        if after.lockScreen == .secure {
            try? ledger.recordFailure(key)
            throw locked("The saved code did not unlock \(name), so Offsider will not type it again until the device is unlocked by hand or the code is saved again with `\(save)`.", hint: save)
        }
        return after
    }

    /// `Motorola moto g57 (ZY22FAKE01): screen on and unlocked (was off, PIN lock screen showing)`.
    static func line(_ outcome: WakeOutcome, name: String) -> String {
        guard !outcome.sent.isEmpty else { return "\(name): screen already on and unlocked" }
        let how = outcome.sent.contains("code") ? " with the saved \(outcome.previous.credential == "pin" ? "PIN" : outcome.previous.credential ?? "code")" : ""
        return "\(name): screen \(outcome.current.screenSummary)\(how) (was \(outcome.previous.screenSummary))"
    }
}
