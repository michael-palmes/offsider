import ArgumentParser
import Foundation
import OffsiderCore
import Testing
@testable import Offsider

/// Codes held in memory, so no test reaches the login Keychain.
final class MemoryUnlockCodeStore: UnlockCodeStoring {
    var codes: [String: UnlockCode] = [:]
    private(set) var reads = 0

    func code(for device: String) throws -> UnlockCode? {
        reads += 1
        return codes[device]
    }

    func hasCode(for device: String) throws -> Bool {
        codes[device] != nil
    }

    func save(_ code: UnlockCode, for device: String) throws {
        codes[device] = code
    }

    func remove(for device: String) throws -> Bool {
        codes.removeValue(forKey: device) != nil
    }
}

@Suite("stay-awake, wake and unlock-code")
@MainActor
struct WakeCommandTests {
    static let phone = DeviceID(rawValue: "ZY22FAKE01", platform: .android)
    static let booted = BootedDevice(id: phone, name: "moto g57")
    static let locked = AwakeReading(screen: .off, lockScreen: .secure, credential: "pin", maker: "motorola")
    static let usable = AwakeReading(screen: .on, lockScreen: .hidden, credential: "pin", maker: "motorola")

    static func backend(_ awake: AwakeReading = usable, afterWake: AwakeReading? = nil) -> FakeDeviceBackend {
        let backend = FakeDeviceBackend(platform: .android, trees: [])
        backend.awake = awake
        backend.afterWake = afterWake
        return backend
    }

    static func wake(
        _ backend: FakeDeviceBackend,
        unlock: Bool = false,
        json: Bool = false,
        store: MemoryUnlockCodeStore = MemoryUnlockCodeStore(),
        ledger: UnlockAttemptLedger
    ) async throws -> String {
        try await Wake.report(unlock: unlock, json: json, booted: booted, backend: backend, store: store, ledger: ledger)
    }

    static func withLedger(_ body: (UnlockAttemptLedger) async throws -> Void) async throws {
        let root = try makePrivateLockRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try await body(UnlockAttemptLedger(root: root))
    }

    static func store(_ text: String) throws -> MemoryUnlockCodeStore {
        let store = MemoryUnlockCodeStore()
        store.codes[phone.rawValue] = try #require(UnlockCode(text))
        return store
    }

    // MARK: stay-awake

    @Test("stay-awake reads off with the screen timeout, and on reports the earlier value")
    func stayAwakeLines() async throws {
        var reading = Self.usable
        reading.charging = [.usb]
        reading.screenTimeoutMilliseconds = 1_800_000
        let backend = Self.backend(reading)

        #expect(try await StayAwakeCommand.report(nil, json: false, booted: Self.booted, backend: backend) == "Motorola moto g57 (ZY22FAKE01): stay awake off (screen timeout 30 min)")
        #expect(try await StayAwakeCommand.report(true, json: false, booted: Self.booted, backend: backend) == "Motorola moto g57 (ZY22FAKE01): stay awake on while charging (was off)")
        #expect(backend.stateCalls == ["awake read", "stay-awake true"])
    }

    @Test("stay-awake says why it has no effect")
    func stayAwakeNoEffect() {
        let notCharging = AwakeReading(screen: .on, lockScreen: .hidden, stayAwake: [.usb], screenTimeoutMilliseconds: 600_000)
        var otherSource = notCharging
        otherSource.charging = [.ac]
        #expect(StayAwakeCommand.line(notCharging, previous: nil, name: "moto g57 (ZY22FAKE01)") == "moto g57 (ZY22FAKE01): stay awake on while charging over USB, but it is not charging, so the screen still turns off after 10 min")
        #expect(StayAwakeCommand.line(otherSource, previous: nil, name: "moto g57 (ZY22FAKE01)") == "moto g57 (ZY22FAKE01): stay awake on while charging over USB, but it charges over AC, so the screen still turns off after 10 min")
        #expect(StayAwakeCommand.line(AwakeReading(screen: .on, lockScreen: .hidden, screenTimeoutMilliseconds: 600_000), previous: notCharging, name: "X") == "X: stay awake off (was on, screen timeout 10 min)")
    }

    @Test("the stay-awake JSON keeps its schema order")
    func stayAwakeJSON() async throws {
        var reading = Self.usable
        reading.charging = [.ac]
        let output = try await StayAwakeCommand.report(true, json: true, booted: Self.booted, backend: Self.backend(reading))
        #expect(output == #"{"version":1,"action":"on","device":"ZY22FAKE01","platform":"android","stayAwake":true,"previous":false,"sources":["ac","usb","wireless","dock"],"charging":["ac"],"effective":true,"timeoutCappedByPolicy":false,"screenTimeoutMs":null,"current":{"screen":"on","lockScreen":"hidden","credential":"pin"}}"#)
    }

    @Test("stay-awake, wake and unlock-code refuse an iOS simulator as not supported")
    func iosRefused() throws {
        let udid = "ABCDEF00-0000-4000-8000-00000000ABCD"
        for command in ["stay-awake", "wake"] {
            let error = try #require(throws: CLIError.self) { try StayAwakeCommand.requireAndroid(udid, command: command) }
            #expect(error.reason == .notSupported)
        }
        #expect((try #require(throws: CLIError.self) { try UnlockCodeCommand.deviceKey(udid) }).reason == .notSupported)
    }

    // MARK: wake

    @Test("wake sends nothing to a usable screen")
    func wakeUsable() async throws {
        try await Self.withLedger { (ledger: UnlockAttemptLedger) async throws in
            let backend = Self.backend()
            #expect(try await Self.wake(backend, ledger: ledger) == "Motorola moto g57 (ZY22FAKE01): screen already on and unlocked")
            #expect(backend.stateCalls == ["wake"])
        }
    }

    @Test("a PIN lock screen without --unlock exits 7 and types nothing, without reading the Keychain")
    func wakeLocked() async throws {
        try await Self.withLedger { (ledger: UnlockAttemptLedger) async throws in
            let backend = Self.backend(Self.locked, afterWake: AwakeReading(screen: .on, lockScreen: .secure, credential: "pin"))
            let store = try Self.store("2580")
            let error = await #expect(throws: CLIError.self) { try await Self.wake(backend, store: store, ledger: ledger) }

            #expect(error?.reason == .deviceLocked)
            #expect(error?.reason.exitCode.rawValue == 7)
            #expect(error?.hint == "offsider wake --unlock --device ZY22FAKE01")
            #expect(backend.enteredCodes.isEmpty)
            #expect(store.reads == 0)
        }
    }

    @Test("--unlock types the saved code once and reports the unlock")
    func wakeUnlocks() async throws {
        try await Self.withLedger { (ledger: UnlockAttemptLedger) async throws in
            let backend = Self.backend(Self.locked, afterWake: AwakeReading(screen: .on, lockScreen: .secure, credential: "pin"))
            backend.afterCode = Self.usable
            let output = try await Self.wake(backend, unlock: true, store: try Self.store("2580"), ledger: ledger)

            #expect(output == "Motorola moto g57 (ZY22FAKE01): screen on and unlocked with the saved PIN (was off, PIN lock screen showing)")
            #expect(backend.enteredCodes.map(\.text) == ["2580"])
        }
    }

    @Test("a rejected code is recorded, and the next --unlock refuses without typing")
    func wakeRejected() async throws {
        try await Self.withLedger { (ledger: UnlockAttemptLedger) async throws in
            let secure = AwakeReading(screen: .on, lockScreen: .secure, credential: "pin")
            let backend = Self.backend(Self.locked, afterWake: secure)
            backend.afterCode = secure
            let store = try Self.store("2580")

            let first = await #expect(throws: CLIError.self) { try await Self.wake(backend, unlock: true, store: store, ledger: ledger) }
            #expect(first?.reason == .deviceLocked)
            #expect(ledger.hasFailed("ZY22FAKE01"))
            let second = await #expect(throws: CLIError.self) { try await Self.wake(backend, unlock: true, store: store, ledger: ledger) }
            #expect(second?.userFacingDescription.contains("last time") == true)
            #expect(backend.enteredCodes.count == 1)
        }
    }

    @Test("a usable screen clears an earlier failure, as an unlock by hand does")
    func usableClearsLedger() async throws {
        try await Self.withLedger { (ledger: UnlockAttemptLedger) async throws in
            try ledger.recordFailure("ZY22FAKE01")
            _ = try await Self.wake(Self.backend(), ledger: ledger)
            #expect(!ledger.hasFailed("ZY22FAKE01"))
        }
    }

    @Test("--unlock refuses a pattern lock and a saved password on a PIN pad without typing")
    func wakeRefusesMismatch() async throws {
        try await Self.withLedger { (ledger: UnlockAttemptLedger) async throws in
            let pattern = Self.backend(Self.locked, afterWake: AwakeReading(screen: .on, lockScreen: .secure, credential: "pattern"))
            await #expect(throws: CLIError.self) { try await Self.wake(pattern, unlock: true, store: try Self.store("2580"), ledger: ledger) }
            let pin = Self.backend(Self.locked, afterWake: AwakeReading(screen: .on, lockScreen: .secure, credential: "pin"))
            await #expect(throws: CLIError.self) { try await Self.wake(pin, unlock: true, store: try Self.store("hunter22"), ledger: ledger) }

            #expect(pattern.enteredCodes.isEmpty)
            #expect(pin.enteredCodes.isEmpty)
            #expect(!ledger.hasFailed("ZY22FAKE01"))
        }
    }

    @Test("--unlock with no saved code names the command that saves one")
    func wakeNoCode() async throws {
        try await Self.withLedger { (ledger: UnlockAttemptLedger) async throws in
            let backend = Self.backend(Self.locked, afterWake: AwakeReading(screen: .on, lockScreen: .secure, credential: "password"))
            let error = await #expect(throws: CLIError.self) { try await Self.wake(backend, unlock: true, ledger: ledger) }
            #expect(error?.hint == "offsider unlock-code set --device ZY22FAKE01")
        }
    }

    @Test("the wake JSON lists what was sent, never the code")
    func wakeJSON() async throws {
        try await Self.withLedger { (ledger: UnlockAttemptLedger) async throws in
            let backend = Self.backend(Self.locked, afterWake: AwakeReading(screen: .on, lockScreen: .secure, credential: "pin"))
            backend.afterCode = Self.usable
            let output = try await Self.wake(backend, unlock: true, json: true, store: try Self.store("2580"), ledger: ledger)
            #expect(output == #"{"version":1,"action":"wake","device":"ZY22FAKE01","platform":"android","sent":["KEYCODE_WAKEUP","dismiss-keyguard","code"],"previous":{"screen":"off","lockScreen":"secure","credential":"pin"},"current":{"screen":"on","lockScreen":"hidden","credential":"pin"}}"#)
            #expect(!output.contains("2580"))
        }
    }

    @Test("an emulator's code is kept under its AVD name, and an unnamed emulator has no key")
    func unlockKeys() {
        let emulator = DeviceID(rawValue: "emulator-5556", platform: .android)
        #expect(Wake.unlockKey(BootedDevice(id: emulator, name: "Offsider_E2E_Pixel_9")) == "Offsider_E2E_Pixel_9")
        #expect(Wake.unlockKey(BootedDevice(id: emulator, name: "emulator-5556")) == nil)
        #expect(Wake.unlockKey(BootedDevice(id: Self.phone, name: "moto g57")) == "ZY22FAKE01")
    }

    // MARK: unlock-code

    @Test("unlock-code saves, reports and removes a code without ever printing it")
    func unlockCodeActions() throws {
        let root = try makePrivateLockRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let ledger = UnlockAttemptLedger(root: root)
        let store = MemoryUnlockCodeStore()
        let code = try #require(UnlockCode("hunter22"))
        func run(_ action: UnlockCodeCommand.Action, json: Bool = false) throws -> String {
            try UnlockCodeCommand.perform(action, device: "FA7AFAKE02", name: "Google Pixel 2 XL (FA7AFAKE02)", json: json, store: store, ledger: ledger) { code }
        }

        try ledger.recordFailure("FA7AFAKE02")
        let outputs = [try run(.set), try run(.status), try run(.status, json: true), try run(.remove), try run(.status)]
        #expect(outputs[1] == "Google Pixel 2 XL (FA7AFAKE02): unlock code saved")
        #expect(outputs[2] == #"{"version":1,"action":"status","device":"FA7AFAKE02","saved":true,"lastAttemptFailed":false}"#)
        #expect(outputs[4] == "Google Pixel 2 XL (FA7AFAKE02): no unlock code saved")
        #expect(outputs.allSatisfy { !$0.contains("hunter22") })
        #expect(store.reads == 0)
    }

    @Test("unlock-code keys a phone by serial and refuses an emulator serial")
    func unlockCodeKeys() throws {
        #expect(try UnlockCodeCommand.deviceKey(" ZY22FAKE01 ") == "ZY22FAKE01")
        #expect(try UnlockCodeCommand.deviceKey("Offsider_E2E_Pixel_9") == "Offsider_E2E_Pixel_9")
        #expect((try #require(throws: CLIError.self) { try UnlockCodeCommand.deviceKey("emulator-5556") }).reason == .usage)
    }

    // MARK: screen hint

    static func route(_ backend: FakeDeviceBackend) -> [DeviceRouter.Route] {
        [DeviceRouter.Route(backend: backend, device: phone)]
    }

    @Test("a selector failure on a locked screen keeps its reason and gains the wake hint")
    func hintAdded() async throws {
        let failure = CLIError(errorDescription: "No accessibility element matched --label 'Save'.", reason: .selectorNotFound)
        let backend = Self.backend(Self.locked)
        backend.listedDeviceName = "moto g57"
        let annotated = await ScreenStateHint.annotate(failure, routes: Self.route(backend))
        let wrapped = try #require(annotated as? ScreenStateFailure)

        #expect(wrapped.reason == .selectorNotFound)
        #expect(wrapped.failureMessage == "No accessibility element matched --label 'Save'. The screen of Motorola moto g57 (ZY22FAKE01) is off, so input and screen reads do not reach the app. Run `offsider wake --device ZY22FAKE01`, then retry.")
        #expect(wrapped.hint == "offsider wake --device ZY22FAKE01")
    }

    @Test("a usable screen, another reason or two devices leave the failure unchanged")
    func hintSkipped() async {
        let notFound = CLIError(errorDescription: "missing", reason: .selectorNotFound)
        let busy = CLIError(errorDescription: "busy", reason: .deviceBusy)
        let locked = Self.backend(Self.locked)
        #expect(await ScreenStateHint.annotate(notFound, routes: Self.route(Self.backend())) is CLIError)
        #expect(await ScreenStateHint.annotate(busy, routes: Self.route(locked)) is CLIError)
        #expect(await ScreenStateHint.annotate(notFound, routes: Self.route(locked) + Self.route(locked)) is CLIError)
        #expect(locked.stateCalls.isEmpty)
    }

    @Test("a condition that was printed already gets a note line and keeps exit 5")
    func hintNote() async {
        var notes: [String] = []
        let exit = ExitCode(OffsiderExitCode.unverified.rawValue)
        let result = await ScreenStateHint.annotate(exit, routes: Self.route(Self.backend(AwakeReading(screen: .on, lockScreen: .secure, credential: "password")))) { notes.append($0) }

        #expect((result as? ExitCode)?.rawValue == 5)
        #expect(notes == ["Note: ZY22FAKE01 is showing its password lock screen, so input and screen reads do not reach the app. Run `offsider wake --device ZY22FAKE01`, then retry."])
    }
}
