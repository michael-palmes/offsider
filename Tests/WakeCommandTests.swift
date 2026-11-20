import ArgumentParser
import Foundation
import OffsiderAndroid
import OffsiderCore
import OffsiderIOSDevice
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

    @Test("stay-awake and unlock-code refuse an iOS simulator as not supported, and stay-awake names the wake that clears a lock screen")
    func iosRefused() throws {
        let udid = "ABCDEF00-0000-4000-8000-00000000ABCD"
        let error = try #require(throws: CLIError.self) { try StayAwakeCommand.requireAndroid(udid, command: "stay-awake") }
        #expect(error.reason == .notSupported)
        #expect(error.userFacingDescription == "stay-awake is Android only: an iOS simulator never sleeps or locks by itself. After `offsider button lock`, `offsider wake --device \(udid)` clears its lock screen.")
        #expect((try #require(throws: CLIError.self) { try UnlockCodeCommand.deviceKey(udid) }).reason == .notSupported)
    }

    // MARK: wake on an iOS simulator

    static let simulator = DeviceID(rawValue: "00000000-0000-0000-0000-000000000001", platform: .ios)
    static let dark = SimulatorLockScreen(locked: true, blanked: true)
    static let lockScreen = SimulatorLockScreen(locked: true, blanked: false)
    static let unlocked = SimulatorLockScreen(locked: false, blanked: false)

    /// A simulator whose lock screen each Home press moves to the next of `afterPresses`; a press past the list changes nothing.
    final class SimulatorLockFake: FakeDeviceBackend, SimulatorLockReading {
        var lock = WakeCommandTests.unlocked
        var afterPresses: [SimulatorLockScreen] = []
        var readError: (any Error)?
        /// Every read after the first press fails, as a notifyutil that stops answering would.
        var failsAfterPress = false
        private(set) var pressedAt: [TimeInterval] = []

        func lockScreen(on id: DeviceID) async throws -> SimulatorLockScreen {
            if let readError { throw readError }
            if failsAfterPress, !pressedAt.isEmpty { throw CLIError(errorDescription: "no answer", reason: .commandFailed) }
            return lock
        }

        func pressed(at time: TimeInterval) {
            pressedAt.append(time)
            if !afterPresses.isEmpty { lock = afterPresses.removeFirst() }
        }
    }

    @Test("button lock on a simulator waits until the lock screen reads as up, so a wake sent next finds it; a long press, another button or an Android device waits for nothing")
    func lockPressWaitsForTheLockScreen() async {
        var clock: TimeInterval = 0
        var reads = 0
        let sleep: (Duration) async throws -> Void = { clock += Double($0.components.seconds) + Double($0.components.attoseconds) / 1e18 }
        // SpringBoard raises the lock state a moment after the press.
        let rising: (DeviceID) async throws -> SimulatorLockScreen = { _ in
            reads += 1
            return clock >= 0.6 ? Self.lockScreen : Self.unlocked
        }
        await Button.awaitSimulatorLock(.lock, duration: nil, device: Self.simulator.rawValue, read: rising, sleep: sleep, now: { clock })
        #expect(clock >= 0.6 && clock < SimulatorWake.lockRise)

        (clock, reads) = (0, 0)
        await Button.awaitSimulatorLock(.lock, duration: nil, device: Self.simulator.rawValue, read: { _ in reads += 1; return Self.unlocked }, sleep: sleep, now: { clock })
        #expect(clock >= SimulatorWake.lockRise && clock < SimulatorWake.lockRise + 0.5, "a lock screen that never comes up is waited for once, then left")

        reads = 0
        await Button.awaitSimulatorLock(.lock, duration: 2, device: Self.simulator.rawValue, read: rising, sleep: sleep, now: { clock })
        await Button.awaitSimulatorLock(.home, duration: nil, device: Self.simulator.rawValue, read: rising, sleep: sleep, now: { clock })
        await Button.awaitSimulatorLock(.lock, duration: nil, device: "emulator-5554", read: rising, sleep: sleep, now: { clock })
        #expect(reads == 0)
    }

    /// Runs the simulator wake on a scripted clock; each sleep moves it on, and each press is stamped with it.
    static func wakeSimulator(_ backend: SimulatorLockFake) async throws -> IOSDeviceScreenChange {
        var clock: TimeInterval = 0
        backend.session.onPerform = { [unowned backend] _ in backend.pressed(at: clock) }
        return try await Wake.wakeSimulator(on: backend, device: simulator, sleep: { duration in
            clock += Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
        }, now: { clock })
    }

    static func homePresses(_ backend: FakeDeviceBackend) -> Int {
        backend.session.calls.filter { $0 == .perform(.shortButtonPress(.home)) }.count
    }

    @Test("a dark lock screen gets Home twice, the second only once a double press is ruled out, and says what was sent")
    func simulatorDarkLockScreen() async throws {
        let backend = SimulatorLockFake(trees: [])
        backend.lock = Self.dark
        backend.afterPresses = [Self.lockScreen, Self.unlocked]
        let change = try await Self.wakeSimulator(backend)
        #expect(Self.homePresses(backend) == 2)
        #expect(backend.pressedAt.count == 2 && backend.pressedAt[1] - backend.pressedAt[0] >= SimulatorWake.gap)
        let view = Wake.iosView(change, device: Self.simulator)
        #expect(view.text == "The screen of \(Self.simulator.rawValue) is on and unlocked (was off); Home pressed 2 times.")
        #expect(view.json == #"{"version":1,"action":"wake","device":"00000000-0000-0000-0000-000000000001","platform":"ios","previous":"off","current":"on, unlocked","sent":["home","home"]}"#)
        #expect(view.person == "Screen on and unlocked")
    }

    @Test("an unlocked simulator gets nothing, as Home would send its app to the home screen")
    func simulatorAlreadyUnlocked() async throws {
        let backend = SimulatorLockFake(trees: [])
        let change = try await Self.wakeSimulator(backend)
        #expect(Self.homePresses(backend) == 0)
        let view = Wake.iosView(change, device: Self.simulator)
        #expect(view.text == "The screen of \(Self.simulator.rawValue) is already on and unlocked; nothing was sent.")
        #expect(view.json.hasSuffix(#""previous":"on, unlocked","current":"on, unlocked","sent":[]}"#))
    }

    @Test("a lit lock screen that one Home clears gets no second press, which would leave the app")
    func simulatorLitLockScreen() async throws {
        let backend = SimulatorLockFake(trees: [])
        backend.lock = Self.lockScreen
        backend.afterPresses = [Self.unlocked]
        let change = try await Self.wakeSimulator(backend)
        #expect(Self.homePresses(backend) == 1)
        #expect(Wake.iosView(change, device: Self.simulator).json.hasSuffix(#""previous":"on, locked","current":"on, unlocked","sent":["home"]}"#))
    }

    @Test("a lock screen still up after two presses is state_not_reached, naming wake again")
    func simulatorStillLocked() async throws {
        let backend = SimulatorLockFake(trees: [])
        backend.lock = Self.dark
        backend.afterPresses = [Self.lockScreen, Self.lockScreen]
        let error = await #expect(throws: CLIError.self) { _ = try await Self.wakeSimulator(backend) }
        #expect(error?.reason == .stateNotReached)
        #expect(error?.hint == "offsider wake --device \(Self.simulator.rawValue)")
        #expect(error?.userFacingDescription.hasPrefix("The lock screen of simulator \(Self.simulator.rawValue) is still up after 2 Home presses.") == true)
        #expect(Self.homePresses(backend) == SimulatorWake.maximumPresses)
    }

    @Test("a lock state that cannot be read presses nothing; one lost after the presses is never reported as unlocked")
    func simulatorUnreadable() async throws {
        let unread = SimulatorLockFake(trees: [])
        unread.readError = CLIError(errorDescription: "Offsider could not read the lock screen", reason: .commandFailed)
        await #expect(throws: CLIError.self) { _ = try await Self.wakeSimulator(unread) }
        #expect(Self.homePresses(unread) == 0)

        let lost = SimulatorLockFake(trees: [])
        lost.lock = Self.dark
        lost.afterPresses = [Self.lockScreen, Self.unlocked]
        lost.failsAfterPress = true
        let error = await #expect(throws: CLIError.self) { _ = try await Self.wakeSimulator(lost) }
        #expect(error?.reason == .stateNotReached)
        #expect(error?.hint == "offsider screenshot --device \(Self.simulator.rawValue)")
    }

    @Test("notifyutil's two flags read as the lock screen; anything less reads as nothing")
    func simulatorLockParse() {
        #expect(SimulatorLockScreen.readArguments(udid: "U") == ["simctl", "spawn", "U", "notifyutil", "-g", "com.apple.springboard.lockstate", "-g", "com.apple.springboard.hasBlankedScreen"])
        #expect(SimulatorLockScreen.parse("com.apple.springboard.lockstate 1\ncom.apple.springboard.hasBlankedScreen 0\n") == Self.lockScreen)
        #expect(SimulatorLockScreen.parse("com.apple.springboard.lockstate 0\ncom.apple.springboard.hasBlankedScreen 0") == Self.unlocked)
        #expect(SimulatorLockScreen.parse("com.apple.springboard.lockstate 1\n") == nil)
        #expect(SimulatorLockScreen.parse("notifyutil: error") == nil)
    }

    @Test("--unlock is refused on a simulator, which has no passcode, and names plain wake")
    func simulatorUnlockRefused() {
        do {
            _ = try Wake.parse(["--unlock", "--device", Self.simulator.rawValue])
            Issue.record("expected a usage error")
        } catch {
            #expect(OffsiderCommand.exitCode(for: error) == .validationFailure)
            #expect(OffsiderCommand.message(for: error).contains("a simulator has no passcode to type. Leave out --unlock: `offsider wake --device \(Self.simulator.rawValue)`"))
        }
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
            #expect(error?.userFacingDescription.hasSuffix("lock screen is showing. Run `offsider wake --unlock --device ZY22FAKE01` to type the saved code, or unlock it on the device.") == true)
            #expect(backend.enteredCodes.isEmpty)
            #expect(store.reads == 0)
        }
    }

    @Test("a PIN lock screen with no code saved names the command a person saves it with, never a wake that would only fail again")
    func wakeLockedUnsaved() async throws {
        try await Self.withLedger { (ledger: UnlockAttemptLedger) async throws in
            let backend = Self.backend(Self.locked, afterWake: AwakeReading(screen: .on, lockScreen: .secure, credential: "pin"))
            let error = await #expect(throws: CLIError.self) { try await Self.wake(backend, ledger: ledger) }
            #expect(error?.hint == "offsider unlock-code set --device ZY22FAKE01")
            #expect(error?.userFacingDescription.contains("save its code in your own terminal with `offsider unlock-code set --device ZY22FAKE01`, then run `offsider wake --unlock --device ZY22FAKE01`") == true)
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

    @Test("--unlock on a phone reads and types the code only after Touch ID, and a cancelled one types nothing")
    func unlockNeedsPersonOnPhone() async throws {
        try await Self.withLedger { (ledger: UnlockAttemptLedger) async throws in
            let store = try Self.store("2580")
            let backend = Self.backend(Self.locked, afterWake: AwakeReading(screen: .on, lockScreen: .secure, credential: "pin"))
            backend.afterCode = Self.usable
            let refused = RecordingPresence(failing: CLIError.personRequired(PersonPresence.cancelledMessage))
            await #expect(throws: CLIError.self) {
                try await PersonPresence.$current.withValue(refused) {
                    _ = try await Wake.result(unlock: true, json: false, booted: Self.booted, backend: backend, store: store, ledger: ledger, confirm: Wake.unlockConsent(whole: false))
                }
            }
            #expect(refused.reasons == ["type the saved unlock code on Motorola moto g (ZY22FAKE01)"])
            #expect(store.reads == 0, "the code stays in the Keychain until a person says yes")
            #expect(backend.enteredCodes.isEmpty)
            #expect(ledger.lastAttempt("ZY22FAKE01") == nil, "nothing was typed, so the code is not blocked")

            let allowed = RecordingPresence()
            _ = try await PersonPresence.$current.withValue(allowed) {
                try await Wake.result(unlock: true, json: false, booted: Self.booted, backend: backend, store: store, ledger: ledger, confirm: Wake.unlockConsent(whole: false))
            }
            #expect(allowed.reasons.count == 1)
            #expect(backend.enteredCodes.map(\.text) == ["2580"])
        }
    }

    @Test("--unlock asks no one on an emulator or a test device, and asks nothing when no code is saved")
    func unlockFreeWhereNothingPersonal() async throws {
        try await Self.withLedger { (ledger: UnlockAttemptLedger) async throws in
            let presence = RecordingPresence()
            let backend = Self.backend(Self.locked, afterWake: AwakeReading(screen: .on, lockScreen: .secure, credential: "pin"))
            backend.afterCode = Self.usable
            _ = try await PersonPresence.$current.withValue(presence) {
                try await Wake.result(unlock: true, json: false, booted: Self.booted, backend: backend, store: try Self.store("2580"), ledger: ledger, confirm: Wake.unlockConsent(whole: true))
            }
            #expect(presence.reasons.isEmpty)
            #expect(backend.enteredCodes.count == 1)

            let none = Self.backend(Self.locked, afterWake: AwakeReading(screen: .on, lockScreen: .secure, credential: "pin"))
            await #expect(throws: CLIError.self) {
                try await PersonPresence.$current.withValue(presence) {
                    _ = try await Wake.result(unlock: true, json: false, booted: Self.booted, backend: none, store: MemoryUnlockCodeStore(), ledger: ledger, confirm: Wake.unlockConsent(whole: false))
                }
            }
            #expect(presence.reasons.isEmpty, "no box for a code that is not there")
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

    @Test("a front-app refusal on a dark or locked phone says the screen first, as screen_off with wake as the fix, and a usable screen keeps the refusal")
    func frontAppRefusalOnDarkScreen() async throws {
        let refusal = AndroidError(.otherAppInFront, "com.android.systemui is part of the system UI, which Offsider never signs in to or drives on a physical phone.")
        let annotated = try #require(await ScreenStateHint.annotate(refusal, routes: Self.route(Self.backend(Self.locked))) as? ScreenStateFailure)
        #expect(annotated.reason == .screenOff && annotated.reason.exitCode == .failure)
        // The command listed no device, so the hint reads it once and names the phone as wake does.
        #expect(annotated.failureMessage.hasPrefix("The screen of Motorola Fake (ZY22FAKE01) is off"))
        #expect(!annotated.failureMessage.contains("system UI"))
        #expect(annotated.hint == "offsider wake --device ZY22FAKE01")

        let usable = await ScreenStateHint.annotate(refusal, routes: Self.route(Self.backend()))
        #expect((usable as? AndroidError)?.reason == .appNotAllowed)

        let notFront = AndroidError(.appNotAllowed, "No app was named.")
        #expect(await ScreenStateHint.annotate(notFront, routes: Self.route(Self.backend(Self.locked))) is AndroidError)
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
        #expect(annotated.userFacingDescription == "com.example.app is in front on ZY22FAKE01, but Android lists no window for it, so the app is not responding or still starting. Wait a moment and retry; if it lasts, run `offsider app launch --restart --app com.example.app --device ZY22FAKE01`.")
        #expect(annotated.hint == "offsider app launch --restart --app com.example.app --device ZY22FAKE01")
        #expect(hung.stateCalls == ["awake read"])

        let launcher = Self.backend()
        launcher.foregrounds = [ForegroundActivities(top: home, home: home)]
        #expect((await ScreenStateHint.annotate(noWindow, routes: Self.route(launcher)) as? CLIError)?.reason == .noWindow)
    }

    @Test("a phone whose allowance does not permit the stuck app asks the person instead of naming a restart it would refuse")
    func hungAppOutsideTheAllowance() throws {
        let allowance = DeviceAllowance(platform: .android, key: Self.phone.rawValue, name: "Test Pixel", added: Date(), expires: nil, apps: ["com.example.other"])
        let route = DeviceRouter.Route(backend: Self.backend(), device: Self.phone, allowance: allowance)
        let failure = AppNotResponding.failure(package: "com.example.app", route: route, policy: { PhysicalDevicePolicy(managed: .none, list: DeviceAllowList(entries: [allowance])) })
        #expect(failure.reason == .appNotResponding)
        #expect(failure.hint == nil)
        #expect(failure.ask == "Can you close and reopen com.example.app on \(PersonAsk.devicePlaceholder)?")
        #expect(!failure.userFacingDescription.contains("app launch"))
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
        #expect(report.contains("The screen of Motorola Fake (ZY22FAKE01) is off"))
        #expect(thrown?.underlying is ScreenStateFailure)
        #expect(thrown?.exitCode.rawValue == 2)
    }

    @Test("a condition that was printed already gets a note line and keeps exit 5")
    func hintNote() async {
        var notes: [String] = []
        let exit = ExitCode(OffsiderExitCode.unverified.rawValue)
        let backend = Self.backend(AwakeReading(screen: .on, lockScreen: .swipe, credential: "none"))
        let result = await ScreenStateHint.annotate(exit, routes: Self.route(backend), store: MemoryUnlockCodeStore()) { notes.append($0) }

        #expect((result as? ExitCode)?.rawValue == 5)
        #expect(notes == ["Note: Fake (ZY22FAKE01) is showing its lock screen, so input and screen reads do not reach the app. Run `offsider wake --device ZY22FAKE01`, then retry."])
    }

    @Test("a PIN or password lock screen names wake --unlock once a code is saved, and saving one when none is, so the hint never loops")
    func lockedHintNamesUnlock() async throws {
        try await Self.withLedger { (ledger: UnlockAttemptLedger) async throws in
            let failure = CLIError(errorDescription: "No accessibility element matched --label 'Save'.", reason: .selectorNotFound)
            let backend = Self.backend(AwakeReading(screen: .on, lockScreen: .secure, credential: "password", maker: "motorola"))
            backend.listedDeviceName = "moto g"

            let saved = try #require(await ScreenStateHint.annotate(failure, routes: Self.route(backend), store: try Self.store("2580"), ledger: ledger) as? ScreenStateFailure)
            #expect(saved.failureMessage.hasSuffix("Motorola moto g (ZY22FAKE01) is showing its password lock screen, so input and screen reads do not reach the app. Run `offsider wake --unlock --device ZY22FAKE01` to type the saved code, or unlock it on the device."))
            #expect(saved.hint == "offsider wake --unlock --device ZY22FAKE01")

            let unsaved = try #require(await ScreenStateHint.annotate(failure, routes: Self.route(backend), store: MemoryUnlockCodeStore(), ledger: ledger) as? ScreenStateFailure)
            #expect(unsaved.failureMessage.contains("`offsider unlock-code set --device ZY22FAKE01`, then run `offsider wake --unlock --device ZY22FAKE01`"))
            #expect(unsaved.hint == "offsider unlock-code set --device ZY22FAKE01")
            #expect(!unsaved.failureMessage.contains("Run `offsider wake --device"))
        }
    }
}
