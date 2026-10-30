import ArgumentParser
import Foundation
import OffsiderCore

struct Wake: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Turn an Android device's screen on and dismiss its lock screen.",
        discussion: """
        Sends nothing when the screen is already on and unlocked. Otherwise it presses the wake key, dismisses the \
        lock screen and waits about 6 s. A PIN, pattern or password lock screen stays up, and the command exits 7 \
        (device_locked) unless --unlock finds a PIN or password saved with `offsider unlock-code set`. Then it types \
        that code once, and only into the lock screen's own focused PIN or password field, as key events through the \
        UiAutomation helper, never as a shell command; without the helper it exits 9 (helper_unavailable), and while \
        record-video or stream-video records the device it exits 8 (device_busy), typing nothing. If the lock screen \
        is still up 15 s after the last key, the code is wrong: Offsider says so and will not type it again until it \
        is saved again. Patterns are not supported. Android only: iOS simulators never sleep.

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
        let console = Console.current
        let result = try await console.progress("Waking the screen") {
            try await route.backend.prepare()
            let booted = try await route.backend.requireBootedDevice(route.device)
            guard let backend = route.backend as? any AwakeControlling else {
                throw CLIError(errorDescription: "wake is not available for \(booted.id.rawValue).", reason: .notSupported)
            }
            return try await Self.result(
                unlock: unlock, json: json, booted: booted,
                backend: backend, store: KeychainUnlockCodeStore(), ledger: UnlockAttemptLedger()
            )
        }
        DevicePersonView.emit(result.text, json: json, person: result.person, console: console)
    }

    /// A phone's serial, or an emulator's AVD name; nil when the AVD name is unknown.
    static func unlockKey(_ booted: BootedDevice) -> String? {
        StableDeviceKey.of(booted)
    }

    /// Messages name the device for people; the commands in them keep the serial, so they still run.
    @MainActor
    static func report(
        unlock: Bool,
        json: Bool,
        booted: BootedDevice,
        backend: any AwakeControlling,
        store: any UnlockCodeStoring,
        ledger: UnlockAttemptLedger,
        recordingLive: (DeviceLockKey) -> Bool = { RecordingMarker.isLive($0) }
    ) async throws -> String {
        try await result(unlock: unlock, json: json, booted: booted, backend: backend, store: store, ledger: ledger, recordingLive: recordingLive).text
    }

    /// The agent's text or JSON, and what a person sees.
    @MainActor
    static func result(
        unlock: Bool,
        json: Bool,
        booted: BootedDevice,
        backend: any AwakeControlling,
        store: any UnlockCodeStoring,
        ledger: UnlockAttemptLedger,
        recordingLive: (DeviceLockKey) -> Bool = { RecordingMarker.isLive($0) }
    ) async throws -> (text: String, person: [Block]) {
        let device = booted.id
        let serial = device.rawValue
        let outcome = try await backend.wake(on: device)
        let name = DeviceName.android(serial: serial, listed: booted.name, maker: outcome.previous.maker)
        var current = outcome.current
        var sent = outcome.sent
        guard current.screen == .on else {
            throw CLIError(errorDescription: "The screen of \(name) did not turn on within about 6 s. Check the device, then retry.", reason: .stateNotReached)
        }
        let unlockKey = Self.unlockKey(booted)
        if current.lockScreen == .secure {
            guard unlock else {
                let pattern = current.credential == "pattern"
                throw CLIError(
                    errorDescription: "The screen of \(name) is on, but its \(current.credentialName) lock screen is showing. "
                        + (pattern ? LockReport.patternHint : "Unlock it on the device, or save its code with `offsider unlock-code set` and run `offsider wake --unlock --device \(serial)`."),
                    reason: .deviceLocked,
                    hint: pattern ? nil : "offsider wake --unlock --device \(serial)"
                )
            }
            let attempt = try await enterSavedCode(
                current, on: device, name: name, key: unlockKey, backend: backend, store: store, ledger: ledger, recordingLive: recordingLive
            )
            current = attempt.reading
            if attempt.typed { sent.append("code") }
        }
        if current.lockScreen == .swipe {
            throw CLIError(errorDescription: "The lock screen of \(name) stayed up after `wm dismiss-keyguard`. Swipe it away on the device.", reason: .deviceLocked)
        }
        if let unlockKey { ledger.clearUnfinished(unlockKey) }
        let result = WakeOutcome(previous: outcome.previous, current: current, sent: sent)
        return (json ? DeviceStateReport.wake(result, on: device) : line(result, name: name), DevicePersonView.wake(result))
    }

    /// One attempt: marked `started` before the first key and `rejected` when the lock screen stays up, so no later command types it again; an untyped one is never marked.
    @MainActor
    static func enterSavedCode(
        _ reading: AwakeReading,
        on device: DeviceID,
        name: String,
        key: String?,
        backend: any AwakeControlling,
        store: any UnlockCodeStoring,
        ledger: UnlockAttemptLedger,
        recordingLive: (DeviceLockKey) -> Bool = { RecordingMarker.isLive($0) }
    ) async throws -> UnlockAttempt {
        func locked(_ message: String, hint: String? = nil) -> CLIError {
            CLIError(errorDescription: message, reason: .deviceLocked, hint: hint)
        }
        try RecordingMarker.refuseTyping("its unlock code", command: "wake", on: device, name: name, recordingLive: recordingLive)
        guard let key else {
            throw locked("Offsider could not read the AVD name of \(name), which its saved code is kept under. Unlock it on the device.")
        }
        let save = UnlockCodeScreen.setCommand(key)
        if reading.credential == "pattern" {
            throw locked("\(name) has a pattern lock screen, and Offsider types only PINs and passwords. Unlock it on the device.")
        }
        if let last = ledger.lastAttempt(key) {
            throw locked(last.message(name: name, device: key), hint: save)
        }
        guard let code = try store.code(for: key) else {
            throw locked("No unlock code is saved for \(name). Unlock it on the device, or save one with `\(save)`.", hint: save)
        }
        if reading.credential == "pin", !code.isPIN {
            throw locked("\(name) asks for a PIN, but its saved code is not 4 to 16 digits, so Offsider typed nothing. Save its PIN with `\(save)`.", hint: save)
        }
        Console.current.relabel("Unlocking \(name)")
        let attempt: UnlockAttempt
        do {
            // The marker goes down before the first key, so a code that never confirms is not typed again by a later run.
            attempt = try await backend.enterUnlockCode(code, on: device) {
                do {
                    try ledger.record(UnlockAttemptRecord(outcome: .started, at: Date(), credential: reading.credential), for: key)
                } catch {
                    throw CLIError(
                        errorDescription: "Offsider could not record the unlock attempt for \(name) (\(error.localizedDescription)), so it typed nothing. Check that \(OffsiderPrivateDirectory.root) is yours and writable, then retry.",
                        reason: .commandFailed
                    )
                }
            }
        } catch let failure as any OffsiderFailure where failure.reason == .deviceLocked {
            throw locked("The lock screen of \(name) showed no PIN or password field, so Offsider typed nothing. Unlock it on the device.")
        }
        guard attempt.typed else {
            if attempt.reading.isUsable { return attempt }
            let retry = "offsider wake --unlock --device \(device.rawValue)"
            throw locked("The screen of \(name) changed before Offsider typed its code, so nothing was typed. Run `\(retry)` again.", hint: retry)
        }
        if attempt.reading.lockScreen == .secure {
            let rejected = UnlockAttemptRecord(outcome: .rejected, at: Date(), credential: reading.credential)
            // A failed write leaves `started`, which still stops a second try.
            try? ledger.record(rejected, for: key)
            throw locked(rejected.message(name: name, device: key, dated: false), hint: save)
        }
        return attempt
    }

    /// `Motorola moto g (ZY22FAKE01): screen on and unlocked (was off, PIN lock screen showing)`.
    static func line(_ outcome: WakeOutcome, name: String) -> String {
        guard !outcome.sent.isEmpty else { return "\(name): screen already on and unlocked" }
        let how = outcome.sent.contains("code") ? " with the saved \(outcome.previous.credential == "pin" ? "PIN" : outcome.previous.credential ?? "code")" : ""
        return "\(name): screen \(outcome.current.screenSummary)\(how) (was \(outcome.previous.screenSummary))"
    }
}
