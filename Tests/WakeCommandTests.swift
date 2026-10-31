import ArgumentParser
import Foundation
import OffsiderCore
import Testing
@testable import Offsider

/// Codes held in memory, so no test reaches the login Keychain.
final class MemoryUnlockCodeStore: UnlockCodeStoring {
    var codes: [String: UnlockCode] = [:]
    private(set) var reads = 0
    /// Thrown by `hasCode`, as a locked login Keychain would.
    var hasCodeError: (any Error)?

    func code(for device: String) throws -> UnlockCode? {
        reads += 1
        return codes[device]
    }

    func hasCode(for device: String) throws -> Bool {
        if let hasCodeError { throw hasCodeError }
        return codes[device] != nil
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
    static let booted = BootedDevice(id: phone, name: "moto g")
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

        #expect(try await StayAwakeCommand.report(nil, json: false, booted: Self.booted, backend: backend) == "Motorola moto g (ZY22FAKE01): stay awake off (screen timeout 30 min)")
        #expect(try await StayAwakeCommand.report(true, json: false, booted: Self.booted, backend: backend) == "Motorola moto g (ZY22FAKE01): stay awake on while charging (was off)")
        #expect(backend.stateCalls == ["awake read", "stay-awake true"])
    }

    @Test("stay-awake says why it has no effect")
    func stayAwakeNoEffect() {
        let notCharging = AwakeReading(screen: .on, lockScreen: .hidden, stayAwake: [.usb], screenTimeoutMilliseconds: 600_000)
        var otherSource = notCharging
        otherSource.charging = [.ac]
        #expect(StayAwakeCommand.line(notCharging, previous: nil, name: "moto g (ZY22FAKE01)") == "moto g (ZY22FAKE01): stay awake on while charging over USB, but it is not charging, so the screen still turns off after 10 min")
        #expect(StayAwakeCommand.line(otherSource, previous: nil, name: "moto g (ZY22FAKE01)") == "moto g (ZY22FAKE01): stay awake on while charging over USB, but it charges over AC, so the screen still turns off after 10 min")
        #expect(StayAwakeCommand.line(AwakeReading(screen: .on, lockScreen: .hidden, screenTimeoutMilliseconds: 600_000), previous: notCharging, name: "X") == "X: stay awake off (was on, screen timeout 10 min)")
        var never = notCharging
        never.screenTimeoutMilliseconds = Int(Int32.max)
        #expect(StayAwakeCommand.line(never, previous: nil, name: "X") == "X: stay awake on while charging over USB; the screen timeout is never, so the screen stays on anyway")
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
            #expect(try await Self.wake(backend, ledger: ledger) == "Motorola moto g (ZY22FAKE01): screen already on and unlocked")
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

            #expect(output == "Motorola moto g (ZY22FAKE01): screen on and unlocked with the saved PIN (was off, PIN lock screen showing)")
            #expect(backend.enteredCodes.map(\.text) == ["2580"])
            #expect(ledger.lastAttempt("ZY22FAKE01") == nil)
        }
    }

    @Test("--unlock refuses with device_busy (exit 8) while a recording runs on the device, before reading the saved code or typing")
    func unlockRefusedWhileRecording() async throws {
        try await Self.withLedger { (ledger: UnlockAttemptLedger) async throws in
            let root = try RecordingMarkerTests.root()
            defer { try? FileManager.default.removeItem(atPath: root) }
            let marker = try RecordingMarker.create(DeviceLockKey(platform: .android, id: Self.phone.rawValue), root: root)
            defer { marker.remove() }
            let backend = Self.backend(Self.locked, afterWake: AwakeReading(screen: .on, lockScreen: .secure, credential: "pin"))
            let store = try Self.store("2580")

            let error = await #expect(throws: CLIError.self) {
                _ = try await Wake.report(
                    unlock: true, json: false, booted: Self.booted, backend: backend, store: store, ledger: ledger,
                    recordingLive: { RecordingMarker.isLive($0, root: root) }
                )
            }

            #expect(error?.reason == .deviceBusy)
            #expect(error?.reason.exitCode.rawValue == 8)
            #expect(error?.failureMessage.contains("A recording is running on Motorola moto g (ZY22FAKE01) (record-video or stream-video), so wake will not type its unlock code") == true)
            #expect(backend.enteredCodes.isEmpty)
            #expect(store.reads == 0)
            #expect(ledger.lastAttempt("ZY22FAKE01") == nil)
        }
    }

    @Test("the marker goes down as started before the first key, so a run that dies mid-code never types it again, and an unlock clears it")
    func markerBeforeTyping() async throws {
        try await Self.withLedger { (ledger: UnlockAttemptLedger) async throws in
            let backend = Self.backend(Self.locked, afterWake: AwakeReading(screen: .on, lockScreen: .secure, credential: "pin"))
            backend.afterCode = Self.usable
            var whileTyping: UnlockAttemptRecord?
            backend.whileTyping = { whileTyping = ledger.lastAttempt("ZY22FAKE01") }
            _ = try await Self.wake(backend, unlock: true, store: try Self.store("2580"), ledger: ledger)

            #expect(whileTyping?.outcome == .started)
            #expect(whileTyping?.credential == "pin")
            #expect(ledger.lastAttempt("ZY22FAKE01") == nil)
        }
    }

    @Test("a marker that cannot be written stops the command with nothing typed")
    func markerWriteFails() async throws {
        let blocked = (NSTemporaryDirectory() as NSString).appendingPathComponent("offsider-ledger-file-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: blocked, contents: Data())
        defer { try? FileManager.default.removeItem(atPath: blocked) }
        let backend = Self.backend(Self.locked, afterWake: AwakeReading(screen: .on, lockScreen: .secure, credential: "pin"))
        backend.afterCode = Self.usable
        let error = await #expect(throws: CLIError.self) {
            try await Self.wake(backend, unlock: true, store: try Self.store("2580"), ledger: UnlockAttemptLedger(root: blocked))
        }

        #expect(error?.userFacingDescription.contains("could not record the unlock attempt") == true)
        #expect(error?.userFacingDescription.contains("so it typed nothing") == true)
        #expect(backend.enteredCodes.isEmpty)
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
            #expect(first?.userFacingDescription == "The saved PIN is wrong: Motorola moto g (ZY22FAKE01) stayed locked after Offsider typed it.\nSave the right one: `offsider unlock-code set --device ZY22FAKE01`\nOffsider won't type it again: repeated wrong PINs can lock a phone out.")
            #expect(first?.hint == "offsider unlock-code set --device ZY22FAKE01")
            #expect(first?.ask == "Can you save the right PIN for \(PersonAsk.devicePlaceholder)? Run this in your own terminal: `offsider unlock-code set --device ZY22FAKE01`")
            #expect(ledger.lastAttempt("ZY22FAKE01")?.outcome == .rejected)
            #expect(ledger.lastAttempt("ZY22FAKE01")?.credential == "pin")

            backend.awake = Self.locked
            let second = await #expect(throws: CLIError.self) { try await Self.wake(backend, unlock: true, store: store, ledger: ledger) }
            #expect(second?.reason == .deviceLocked)
            #expect(second?.userFacingDescription.hasPrefix("The saved PIN is wrong: Motorola moto g (ZY22FAKE01) stayed locked after Offsider typed it on ") == true)
            #expect(second?.hint == "offsider unlock-code set --device ZY22FAKE01")
            #expect(second?.ask == first?.ask)
            #expect(backend.enteredCodes.count == 1)
            #expect(store.reads == 1)
        }
    }

    @Test("a run that fails after the marker went down says Offsider can't tell, and the next one types nothing")
    func wakeNoResult() async throws {
        try await Self.withLedger { (ledger: UnlockAttemptLedger) async throws in
            let secure = AwakeReading(screen: .on, lockScreen: .secure, credential: "pin")
            let backend = Self.backend(Self.locked, afterWake: secure)
            backend.codeError = CLIError(errorDescription: "The helper stopped.", reason: .commandFailed)
            let store = try Self.store("2580")

            let first = await #expect(throws: CLIError.self) { try await Self.wake(backend, unlock: true, store: store, ledger: ledger) }
            #expect(first?.reason == .commandFailed)
            #expect(ledger.lastAttempt("ZY22FAKE01")?.outcome == .started)

            backend.awake = Self.locked
            let second = await #expect(throws: CLIError.self) { try await Self.wake(backend, unlock: true, store: store, ledger: ledger) }
            #expect(second?.reason == .deviceLocked)
            #expect(second?.userFacingDescription.hasPrefix("Offsider can't tell if the saved PIN is right: it has no result for its unlock of Motorola moto g (ZY22FAKE01) on ") == true)
            #expect(second?.hint == "offsider unlock-code set --device ZY22FAKE01")
            #expect(second?.ask == "Can you save the PIN for \(PersonAsk.devicePlaceholder) again? Run this in your own terminal: `offsider unlock-code set --device ZY22FAKE01`")
            #expect(backend.enteredCodes.count == 1)
        }
    }

    @Test("a lock screen with no saved-code problem still asks the user to unlock, and the ask names the device when reported")
    func plainLockedAsk() async throws {
        try await Self.withLedger { (ledger: UnlockAttemptLedger) async throws in
            let backend = Self.backend(Self.locked, afterWake: AwakeReading(screen: .on, lockScreen: .secure, credential: "pin"))
            let error = await #expect(throws: CLIError.self) { try await Self.wake(backend, ledger: ledger) }
            #expect(error?.ask == "Can you unlock \(PersonAsk.devicePlaceholder)?")

            let record = UnlockAttemptRecord(outcome: .rejected, at: nil, credential: "pin")
            #expect(PersonAsk.filled(record.ask(device: "ZY22FAKE01"), name: "moto g (ZY22FAKE01)", id: "ZY22FAKE01") == "Can you save the right PIN for moto g (ZY22FAKE01)? Run this in your own terminal: `offsider unlock-code set --device ZY22FAKE01`")
        }
    }

    @Test("an empty marker from an earlier version types nothing and says Offsider can't tell")
    func wakeOldMarker() async throws {
        let root = try makePrivateLockRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let ledger = UnlockAttemptLedger(root: root)
        try ledger.record(UnlockAttemptRecord(outcome: .started, at: nil, credential: nil), for: "ZY22FAKE01")
        let path = ((root as NSString).appendingPathComponent(UnlockAttemptLedger.directoryName) as NSString).appendingPathComponent("device-ZY22FAKE01.failed")
        try Data().write(to: URL(fileURLWithPath: path))

        let backend = Self.backend(Self.locked, afterWake: AwakeReading(screen: .on, lockScreen: .secure, credential: "pin"))
        let error = await #expect(throws: CLIError.self) { try await Self.wake(backend, unlock: true, store: try Self.store("2580"), ledger: ledger) }
        #expect(error?.userFacingDescription.hasPrefix("Offsider can't tell if the saved code is right: ") == true)
        #expect(backend.enteredCodes.isEmpty)
    }

    @Test("a person reads a wrong PIN as the cause, then the command on its own line, with no second Try line")
    func wrongCodeForAPerson() {
        let record = UnlockAttemptRecord(outcome: .rejected, at: nil, credential: "pin")
        let message = record.message(name: "moto g (ZY22FAKE01)", device: "ZY22FAKE01", dated: false)
        let shown = PersonRenderer.error(message, hint: "offsider unlock-code set --device ZY22FAKE01", canvas: Canvas(columns: 80, style: .plain))
        #expect(shown == """
        ❌  The saved PIN is wrong: moto g (ZY22FAKE01) stayed locked after
            Offsider typed it.
            Save the right one: offsider unlock-code set --device ZY22FAKE01
            Offsider won't type it again: repeated wrong PINs can lock a phone
            out.

        """)
    }

    @Test("a code that was never typed, because the screen changed first, is not recorded as rejected")
    func untypedCodeNotRecorded() async throws {
        try await Self.withLedger { (ledger: UnlockAttemptLedger) async throws in
            let backend = Self.backend(Self.locked, afterWake: AwakeReading(screen: .on, lockScreen: .secure, credential: "pin"))
            backend.codeTyped = false
            backend.afterCode = AwakeReading(screen: .off, lockScreen: .secure, credential: "pin")
            let error = await #expect(throws: CLIError.self) { try await Self.wake(backend, unlock: true, store: try Self.store("2580"), ledger: ledger) }

            #expect(error?.userFacingDescription.contains("nothing was typed") == true)
            #expect(error?.hint == "offsider wake --unlock --device ZY22FAKE01")
            #expect(ledger.lastAttempt("ZY22FAKE01") == nil)
        }
    }

    @Test("a usable screen settles an attempt with no result, as an unlock by hand does, but a wrong code stays until it is saved again")
    func usableSettlesLedger() async throws {
        try await Self.withLedger { (ledger: UnlockAttemptLedger) async throws in
            try ledger.record(UnlockAttemptRecord(outcome: .started, at: Date(), credential: "pin"), for: "ZY22FAKE01")
            _ = try await Self.wake(Self.backend(), ledger: ledger)
            #expect(ledger.lastAttempt("ZY22FAKE01") == nil)

            try ledger.record(UnlockAttemptRecord(outcome: .rejected, at: Date(), credential: "pin"), for: "ZY22FAKE01")
            _ = try await Self.wake(Self.backend(), ledger: ledger)
            #expect(ledger.lastAttempt("ZY22FAKE01")?.outcome == .rejected)

            let store = try Self.store("2580")
            let locked = Self.backend(Self.locked, afterWake: AwakeReading(screen: .on, lockScreen: .secure, credential: "pin"))
            await #expect(throws: CLIError.self) { try await Self.wake(locked, unlock: true, store: store, ledger: ledger) }
            #expect(locked.enteredCodes.isEmpty)

            _ = try UnlockCodeCommand.perform(.set, device: "ZY22FAKE01", json: false, store: store, ledger: ledger) { try #require(UnlockCode("1379")) }
            #expect(ledger.lastAttempt("ZY22FAKE01") == nil)
            locked.afterCode = Self.usable
            _ = try await Self.wake(locked, unlock: true, store: store, ledger: ledger)
            #expect(locked.enteredCodes.count == 1)
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
            #expect(ledger.lastAttempt("ZY22FAKE01") == nil)
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
        #expect(Wake.unlockKey(BootedDevice(id: emulator, name: "Offsider_E2E")) == "Offsider_E2E")
        #expect(Wake.unlockKey(BootedDevice(id: emulator, name: "emulator-5556")) == nil)
        #expect(Wake.unlockKey(BootedDevice(id: Self.phone, name: "moto g")) == "ZY22FAKE01")
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
            try UnlockCodeCommand.perform(action, device: "FA7AFAKE02", name: "Google Pixel (FA7AFAKE02)", json: json, store: store, ledger: ledger) { code }
        }

        try ledger.record(UnlockAttemptRecord(outcome: .rejected, at: Date(), credential: "pin"), for: "FA7AFAKE02")
        let outputs = [try run(.set), try run(.status), try run(.status, json: true), try run(.remove), try run(.status)]
        #expect(outputs[1] == "Google Pixel (FA7AFAKE02): unlock code saved")
        #expect(outputs[2] == #"{"version":1,"action":"status","device":"FA7AFAKE02","saved":true,"lastAttemptFailed":false,"lastAttempt":null}"#)
        #expect(outputs[4] == "Google Pixel (FA7AFAKE02): no unlock code saved")
        #expect(outputs.allSatisfy { !$0.contains("hunter22") })
        #expect(store.reads == 0)
    }

    @Test("unlock-code status says a saved code is wrong, or that Offsider can't tell, and the JSON gives the outcome and time")
    func unlockCodeStatusWithAttempt() throws {
        let root = try makePrivateLockRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let ledger = UnlockAttemptLedger(root: root)
        let store = MemoryUnlockCodeStore()
        store.codes["FA7AFAKE02"] = try #require(UnlockCode("2580"))
        func run(json: Bool = false) throws -> String {
            try UnlockCodeCommand.perform(.status, device: "FA7AFAKE02", name: "Google Pixel (FA7AFAKE02)", json: json, store: store, ledger: ledger) { throw CLIError(errorDescription: "Only set reads a code.", reason: .usage) }
        }

        try ledger.record(UnlockAttemptRecord(outcome: .rejected, at: Date(timeIntervalSince1970: 1_790_000_000), credential: "pin"), for: "FA7AFAKE02")
        #expect(try run().hasPrefix("The saved PIN is wrong: Google Pixel (FA7AFAKE02) stayed locked after Offsider typed it on "))
        #expect(try run().contains("Save the right one: `offsider unlock-code set --device FA7AFAKE02`"))
        #expect(try run(json: true) == #"{"version":1,"action":"status","device":"FA7AFAKE02","saved":true,"lastAttemptFailed":true,"lastAttempt":{"outcome":"rejected","at":"2026-09-21T14:13:20Z","credential":"pin"}}"#)

        try ledger.record(UnlockAttemptRecord(outcome: .started, at: Date(timeIntervalSince1970: 1_790_000_000), credential: "pin"), for: "FA7AFAKE02")
        #expect(try run().hasPrefix("Offsider can't tell if the saved PIN is right: it has no result for its unlock of Google Pixel (FA7AFAKE02) on "))
        #expect(try run().contains("Save it again: `offsider unlock-code set --device FA7AFAKE02`"))
        #expect(store.reads == 0)
    }

    @Test("unlock-code keys a phone by serial and refuses an emulator serial")
    func unlockCodeKeys() throws {
        #expect(try UnlockCodeCommand.deviceKey(" ZY22FAKE01 ") == "ZY22FAKE01")
        #expect(try UnlockCodeCommand.deviceKey("Offsider_E2E") == "Offsider_E2E")
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
        backend.listedDeviceName = "moto g"
        let annotated = await ScreenStateHint.annotate(failure, routes: Self.route(backend))
        let wrapped = try #require(annotated as? ScreenStateFailure)

        #expect(wrapped.reason == .selectorNotFound)
        #expect(wrapped.failureMessage == "No accessibility element matched --label 'Save'. The screen of Motorola moto g (ZY22FAKE01) is off, so input and screen reads do not reach the app. Run `offsider wake --device ZY22FAKE01`, then retry.")
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

    @Test("no window on an unlocked screen with an app in front is app_not_responding, not a hint to unlock; the home screen in front keeps no_window")
    func hungAppHint() async throws {
        let noWindow = CLIError(errorDescription: "Offsider found no window on ZY22FAKE01. Unlock it and bring an app to the front.", reason: .noWindow)
        let home = "com.example.launcher/com.example.launcher.Home"
        let hung = Self.backend()
        hung.foregrounds = [ForegroundActivities(top: "com.example.app/com.example.app.MainActivity", home: home)]
        let annotated = try #require(await ScreenStateHint.annotate(noWindow, routes: Self.route(hung)) as? CLIError)
        #expect(annotated.reason == .appNotResponding)
        #expect(annotated.userFacingDescription == "com.example.app is in front on ZY22FAKE01, but Android lists no window for it, so the app is not responding or still starting. Wait a moment and retry; if it lasts, close the app and open it again.")
        #expect(hung.stateCalls == ["awake read"])

        let launcher = Self.backend()
        launcher.foregrounds = [ForegroundActivities(top: home, home: home)]
        #expect((await ScreenStateHint.annotate(noWindow, routes: Self.route(launcher)) as? CLIError)?.reason == .noWindow)
    }

    @Test("the screen check runs once per command, so an early report and the final error share one probe")
    func hintOncePerCommand() async {
        let backend = Self.backend(Self.locked)
        let scope = CommandScope()
        scope.noteRoute(DeviceRouter.Route(backend: backend, device: Self.phone))
        let failure = CLIError(errorDescription: "missing", reason: .selectorNotFound)

        #expect(await scope.screenHint(for: failure) is ScreenStateFailure)
        #expect(await scope.screenHint(for: failure) is CLIError)
        #expect(backend.stateCalls == ["awake read"])
    }

    @Test("a --verify --json selector failure on a locked screen carries the wake hint in its JSON error")
    func verifyJSONHint() async throws {
        let scope = CommandScope()
        scope.noteRoute(DeviceRouter.Route(backend: Self.backend(Self.locked), device: Self.phone))
        var written = Data()
        let options = try VerificationOptions.parse(["--verify", "--json"])
        let thrown = await #expect(throws: ReportedFailure.self) {
            try await VerifyOutput.reportingFailures(command: "tap", target: "label=Save", options: options, scope: scope, write: { written.append($0) }) { _ in
                throw CLIError(errorDescription: "No accessibility element matched --label 'Save'.", reason: .selectorNotFound)
            }
        }

        let report = String(decoding: written, as: UTF8.self)
        #expect(report.contains("offsider wake --device ZY22FAKE01"))
        #expect(report.contains("The screen of Motorola (ZY22FAKE01) is off"))
        #expect(thrown?.underlying is ScreenStateFailure)
        #expect(thrown?.exitCode.rawValue == 2)
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
