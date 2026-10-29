import Foundation
import OffsiderCore
import Testing
@testable import Offsider

@Suite("Android orientation keeps auto-rotate")
@MainActor
final class OrientationAutoRotateTests {
    nonisolated static let serial = "fake-phone-serial"
    nonisolated static let bootA = "4c2b6f1e-9d3a-4f0b-8e2d-1a2b3c4d5e6f"
    nonisolated static let bootB = "9a8b7c6d-5e4f-4a3b-8c2d-1e0f9a8b7c6d"

    /// A phone's auto-rotate settings and boot id; `turn` writes auto-rotate off, as `settings put` does.
    @MainActor
    final class Phone {
        var accelerometer: Int
        var userRotation: Int
        var bootID: String?
        var readError: (any Error)?
        /// Puts of auto-rotate the phone ignores before one sticks.
        var ignoredAccelerometerPuts = 0
        /// The app in front locks portrait, so a turn writes the settings but the screen stays put.
        var appLocksPortrait = false
        private(set) var screen: DeviceOrientation
        private(set) var turns = 0
        private(set) var writes: [Int] = []

        init(accelerometer: Int, userRotation: Int = 0, screen: DeviceOrientation = .portrait, bootID: String? = OrientationAutoRotateTests.bootA) {
            self.accelerometer = accelerometer
            self.userRotation = userRotation
            self.screen = screen
            self.bootID = bootID
        }

        func turn(to target: DeviceOrientation, in store: RotationRecordStore, emulatorMarker: String? = nil) async throws -> RotationReport {
            try await OrientationCommand.turnKeepingAutoRotate(
                target: target,
                turning: screen != target,
                serial: OrientationAutoRotateTests.serial,
                emulatorMarker: emulatorMarker,
                store: store,
                read: {
                    if let error = self.readError { throw error }
                    return AutoRotateState(accelerometerRotation: self.accelerometer, userRotation: self.userRotation, bootID: self.bootID)
                },
                writeAccelerometer: { value in
                    self.writes.append(value)
                    if self.ignoredAccelerometerPuts > 0 {
                        self.ignoredAccelerometerPuts -= 1
                    } else {
                        self.accelerometer = value
                    }
                },
                writeUserRotation: { self.userRotation = $0 },
                turn: {
                    self.turns += 1
                    self.accelerometer = 0
                    self.userRotation = target.androidRotation
                    if self.appLocksPortrait, target != .portrait {
                        throw CLIError(errorDescription: "The phone did not turn", reason: .stateNotReached)
                    }
                    self.screen = target
                },
                warn: { _ in }
            )
        }
    }

    let store = RotationRecordStore(root: (NSTemporaryDirectory() as NSString).appendingPathComponent("offsider-rotation-test-\(UUID().uuidString)"))

    deinit {
        try? FileManager.default.removeItem(atPath: store.root)
    }

    @Test("a phone held in landscape with auto-rotate on turns portrait and keeps auto-rotate on")
    func portraitFromLandscapeRestores() async throws {
        let phone = Phone(accelerometer: 1, userRotation: 1, screen: .landscapeLeft)

        let report = try await phone.turn(to: .portrait, in: store)

        #expect(phone.turns == 1)
        #expect(phone.accelerometer == 1)
        #expect(report.restored)
        #expect(store.read(Self.serial) == nil)
    }

    @Test("portrait after a turn the app refused puts auto-rotate and user_rotation back, though the screen never left portrait")
    func portraitAfterRefusedTurnRestoresBoth() async throws {
        let phone = Phone(accelerometer: 1, userRotation: 0)
        phone.appLocksPortrait = true

        await #expect(throws: CLIError.self) { try await phone.turn(to: .landscapeLeft, in: store) }
        #expect(phone.accelerometer == 0 && phone.userRotation == 1)
        let report = try await phone.turn(to: .portrait, in: store)

        #expect(phone.accelerometer == 1)
        #expect(phone.userRotation == 0)
        #expect(report.restored)
        #expect(report.now?.userRotation == 0)
        #expect(store.read(Self.serial) == nil)
    }

    @Test("auto-rotate that reads back unchanged after one put is put again")
    func accelerometerPutTwice() async throws {
        let phone = Phone(accelerometer: 1)
        _ = try await phone.turn(to: .landscapeLeft, in: store)
        phone.ignoredAccelerometerPuts = 1

        let report = try await phone.turn(to: .portrait, in: store)

        #expect(phone.writes == [1, 1])
        #expect(phone.accelerometer == 1)
        #expect(report.restored)
    }

    @Test("auto-rotate that never reads back is reported unrestored and its record kept for the next portrait")
    func accelerometerNeverSticks() async throws {
        let phone = Phone(accelerometer: 1, userRotation: 1)
        _ = try await phone.turn(to: .landscapeLeft, in: store)
        phone.ignoredAccelerometerPuts = 2

        let report = try await phone.turn(to: .portrait, in: store)

        #expect(!report.restored)
        #expect(phone.userRotation == 0)
        #expect(store.read(Self.serial) != nil)
    }

    @Test("with auto-rotate off before the first turn, portrait leaves user_rotation at portrait rather than the landscape it was locked to")
    func lockedLandscapeStaysPortrait() async throws {
        let phone = Phone(accelerometer: 0, userRotation: 1)

        _ = try await phone.turn(to: .landscapeLeft, in: store)
        _ = try await phone.turn(to: .portrait, in: store)

        #expect(phone.accelerometer == 0)
        #expect(phone.userRotation == 0)
    }

    @Test("unreadable auto-rotate refuses the turn, so auto-rotate is never switched off without a record", arguments: [DeviceOrientation.portrait, .landscapeLeft])
    func unreadableRefuses(target: DeviceOrientation) async throws {
        let phone = Phone(accelerometer: 1, screen: .portraitUpsideDown)
        phone.readError = CLIError(errorDescription: "adb went away")

        let error = await #expect(throws: CLIError.self) { try await phone.turn(to: target, in: store) }

        #expect(error?.reason == .deviceControlFailed)
        #expect(error?.userFacingDescription.contains("adb went away") == true)
        #expect(phone.turns == 0)
        #expect(phone.accelerometer == 1)
        #expect(store.read(Self.serial) == nil)
    }

    @Test("a record that cannot be saved refuses the turn")
    func unsavedRecordRefuses() async throws {
        let blocker = (NSTemporaryDirectory() as NSString).appendingPathComponent("offsider-rotation-file-\(UUID().uuidString)")
        try Data().write(to: URL(fileURLWithPath: blocker))
        defer { try? FileManager.default.removeItem(atPath: blocker) }
        let phone = Phone(accelerometer: 1)

        let error = await #expect(throws: CLIError.self) {
            try await phone.turn(to: .landscapeLeft, in: RotationRecordStore(root: (blocker as NSString).appendingPathComponent("root")))
        }

        #expect(error?.userFacingDescription.contains("so it did not turn the device or change auto-rotate") == true)
        #expect(phone.turns == 0)
        #expect(phone.accelerometer == 1)
    }

    @Test("a phone's record names its boot, so a record from before a reboot is never written back")
    func rebootForgetsRecord() async throws {
        let phone = Phone(accelerometer: 1)

        _ = try await phone.turn(to: .landscapeLeft, in: store)
        #expect(store.read(Self.serial)?.bootMarker == "boot_id \(Self.bootA)")

        phone.bootID = Self.bootB
        phone.accelerometer = 0
        let report = try await phone.turn(to: .portrait, in: store)

        #expect(phone.writes == [0])
        #expect(report.restored)
    }

    @Test("an emulator's record keeps its process marker")
    func emulatorMarkerWins() async throws {
        let phone = Phone(accelerometer: 1)

        _ = try await phone.turn(to: .landscapeLeft, in: store, emulatorMarker: "emulator 1790000000.000001")

        #expect(store.read(Self.serial)?.bootMarker == "emulator 1790000000.000001")
    }
}
