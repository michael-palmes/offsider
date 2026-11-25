import ArgumentParser
import Foundation
import OffsiderCore
import OffsiderIOSDevice

struct Wake: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Turn a screen on and dismiss its lock screen.",
        discussion: """
        Sends nothing when the screen is already on and unlocked. Otherwise it presses the wake key, dismisses the \
        lock screen and waits about 6 s. A PIN, pattern or password lock screen stays up, and the command exits 7 \
        (device_locked) unless --unlock finds a PIN or password saved with `offsider unlock-code set`. Then it types \
        that code once, and only into the lock screen's own focused PIN or password field, as key events through the \
        UiAutomation helper, never as a shell command; without the helper it exits 9 (helper_unavailable), and while \
        record-video or stream-video records the device it exits 8 (device_busy), typing nothing. If the lock screen \
        is still up 15 s after the last key, the code is wrong: Offsider says so and will not type it again until it \
        is saved again. Patterns are not supported.

        On an allowed iPhone or iPad it presses Home at most twice, without needing an app in front, and exits 7 \
        (device_locked) when a passcode stays up; Offsider never types one, so --unlock is refused.

        On an iOS simulator it clears the lock screen `button lock` leaves: it reads SpringBoard's lock state and, \
        only while the lock screen is up, presses Home at most twice (never a swipe up, which can freeze the display), \
        then checks the lock screen has gone. `button lock` waits until the lock screen is up, so wake can follow it \
        at once. A simulator has no passcode, so --unlock is refused there too.

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

    func validate() throws {
        guard unlock else { return }
        switch DeviceIDClassifier.classify(deviceOption.id) {
        case .iosDevice:
            throw ValidationError("--unlock is Android only: Offsider never types an iPhone or iPad passcode. Unlock it by hand.")
        case .iosSimulator:
            throw ValidationError("--unlock is Android only: a simulator has no passcode to type. Leave out --unlock: `offsider wake --device \(deviceOption.id)` clears its lock screen.")
        default:
            break
        }
    }

    func run() async throws {
        switch DeviceIDClassifier.classify(deviceOption.id) {
        case .iosDevice:
            try await wakeIOSDevice()
            return
        case .iosSimulator:
            try await wakeSimulator()
            return
        default:
            break
        }
        try StayAwakeCommand.requireAndroid(deviceOption.id, command: "wake")
        if unlock { try CLIError.requireManaged(.allowUnlockCodes, outcome: "Nothing was sent to \(deviceOption.id).") }
        let route = try await DeviceRouter.routeForInput(deviceOption, logger: OffsiderLogger())
        let console = Console.current
        let result = try await console.progress("Waking the screen") {
            try await route.backend.prepare()
            let booted = try await route.backend.requireBootedDevice(route.device)
            guard let backend = route.backend as? any AwakeControlling else {
                throw CLIError(errorDescription: "wake is not available for \(booted.id.rawValue).", reason: .notSupported)
            }
            let whole = route.allowance.map { DevicePolicyGate.current.policy().drivesWhole($0) } ?? !route.device.isPhysicalAndroidDevice
            return try await Self.result(
                unlock: unlock, json: json, booted: booted,
                backend: backend, store: KeychainUnlockCodeStore(), ledger: UnlockAttemptLedger(), confirm: Self.unlockConsent(whole: whole)
            )
        }
        DevicePersonView.emit(result.text, json: json, person: result.person, console: console)
    }

    private func wakeIOSDevice() async throws {
        let route = try await DeviceRouter.routeForInput(deviceOption, logger: OffsiderLogger())
        guard let backend = route.backend as? IOSDeviceBackend else {
            throw CLIError(errorDescription: "wake is not available for \(route.device.rawValue).", reason: .notSupported)
        }
        let console = Console.current
        let change = try await console.progress("Waking the screen") { try await backend.wakeScreen(route.device) }
        let view = Self.iosView(change, device: route.device)
        DevicePersonView.emit(json ? view.json : view.text, json: json, person: DevicePersonView.receipt(view.person), console: console)
    }

    private func wakeSimulator() async throws {
        let route = try await DeviceRouter.routeForInput(deviceOption, logger: OffsiderLogger())
        guard let backend = route.backend as? any SimulatorLockReading else {
            throw CLIError(errorDescription: "wake is not available for \(route.device.rawValue).", reason: .notSupported)
        }
        let console = Console.current
        let change = try await console.progress("Clearing the lock screen") {
            try await route.backend.prepare()
            _ = try await route.backend.requireBootedDevice(route.device)
            return try await Self.wakeSimulator(on: backend, device: route.device)
        }
        let view = Self.iosView(change, device: route.device)
        DevicePersonView.emit(json ? view.json : view.text, json: json, person: DevicePersonView.receipt(view.person), console: console)
    }

    /// Home at most twice, only while SpringBoard's lock screen is up; the same change an iPhone reports.
    @MainActor
    static func wakeSimulator(
        on backend: any SimulatorLockReading,
        device: DeviceID,
        sleep: (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) async throws -> IOSDeviceScreenChange {
        let outcome = try await SimulatorWake.run(
            read: { try await backend.lockScreen(on: device) },
            press: { try await backend.performTracked(.shortButtonPress(.home), on: device) },
            sleep: sleep,
            now: now
        )
        let udid = device.rawValue
        let again = "offsider wake --device \(udid)"
        switch outcome {
        case .alreadyUnlocked:
            return IOSDeviceScreenChange(wasOn: true, wasLocked: false, presses: 0)
        case .unlocked(let before, let presses):
            return IOSDeviceScreenChange(wasOn: !before.blanked, wasLocked: true, presses: presses)
        case .stillLocked(_, let presses):
            throw CLIError(
                errorDescription: "The lock screen of simulator \(udid) is still up after \(presses) Home presses. Run `\(again)` again; if it stays, run `offsider doctor --device \(udid)`.",
                reason: .stateNotReached, hint: again
            )
        case .unconfirmed(_, let presses):
            throw CLIError(
                errorDescription: "Offsider pressed Home \(presses) times on simulator \(udid), but could not read its lock screen afterwards. Check it with `offsider screenshot --device \(udid)`.",
                reason: .stateNotReached, hint: "offsider screenshot --device \(udid)"
            )
        }
    }

    static func iosView(_ change: IOSDeviceScreenChange, device: DeviceID) -> (text: String, json: String, person: String) {
        let was = change.wasOn ? (change.wasLocked ? "on, locked" : "on, unlocked") : "off"
        let json = DeviceStateReport.screen("wake", on: device, previous: was, current: "on, unlocked", sent: Array(repeating: "home", count: change.presses))
        guard change.presses > 0 else { return ("The screen of \(device.rawValue) is already on and unlocked; nothing was sent.", json, "Screen already on and unlocked") }
        return ("The screen of \(device.rawValue) is on and unlocked (was \(was)); Home pressed \(change.presses) time\(change.presses == 1 ? "" : "s").", json, "Screen on and unlocked")
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

    /// Nothing to ask on an emulator or test device; a phone someone may use needs Touch ID or the password before its code is read.
    static func unlockConsent(whole: Bool) -> @Sendable (String) async throws -> Void {
        guard !whole else { return { _ in } }
        return { name in try await PersonPresence.confirm(reason: "type the saved unlock code on \(PromptScreen.label(name))") }
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
        confirm: (String) async throws -> Void = { _ in },
        recordingLive: (DeviceLockKey) -> Bool = { RecordingMarker.isLive($0) }
    ) async throws -> (text: String, person: [Block]) {
        let device = booted.id
        let serial = device.rawValue
        let outcome = try await backend.wake(on: device)
        let name = DeviceName.android(serial: serial, listed: booted.name, maker: outcome.previous.maker)
        ErrorReporter.noteDeviceName(name)
        var current = outcome.current
        var sent = outcome.sent
        guard current.screen == .on else {
            throw CLIError(errorDescription: "The screen of \(name) did not turn on within about 6 s. Check the device, then retry.", reason: .stateNotReached)
        }
        let unlockKey = Self.unlockKey(booted)
        if current.lockScreen == .secure {
            guard unlock else {
                // With a code saved, the step is `wake --unlock`; without one, saving it, which only a person can do.
                let step = ScreenStateHint.fix(serial: serial, reading: current, codeKey: unlockKey, store: store, ledger: ledger)
                throw CLIError(
                    errorDescription: "The screen of \(name) is on, but its \(current.credentialName) lock screen is showing. \(step.text)",
                    reason: .deviceLocked,
                    hint: step.hint
                )
            }
            let attempt = try await enterSavedCode(
                current, on: device, name: name, key: unlockKey, backend: backend, store: store, ledger: ledger, confirm: confirm, recordingLive: recordingLive
            )
            current = attempt.reading
            if attempt.typed { sent.append("code") }
        }
        if current.lockScreen == .swipe {
            guard current.credential != nil || current.keyguardSecure != nil else {
                let doctor = "offsider doctor --device \(serial)"
                throw CLIError(
                    errorDescription: "The lock screen of \(name) stayed up after `wm dismiss-keyguard`, and Offsider could not read whether it needs a code. Run `\(doctor)`, or unlock it on the device.",
                    reason: .deviceLocked,
                    hint: doctor
                )
            }
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
        confirm: (String) async throws -> Void = { _ in },
        recordingLive: (DeviceLockKey) -> Bool = { RecordingMarker.isLive($0) }
    ) async throws -> UnlockAttempt {
        func locked(_ message: String, hint: String? = nil, ask: String? = nil) -> CLIError {
            CLIError(errorDescription: message, reason: .deviceLocked, hint: hint, ask: ask)
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
            throw locked(last.message(name: name, device: key), hint: save, ask: last.ask(device: key))
        }
        let missing = locked("No unlock code is saved for \(name). Unlock it on the device, or save one with `\(save)`.", hint: save)
        guard try store.hasCode(for: key) else { throw missing }
        try await confirm(name)
        guard let code = try store.code(for: key) else { throw missing }
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
            throw locked(rejected.message(name: name, device: key, dated: false), hint: save, ask: rejected.ask(device: key))
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
