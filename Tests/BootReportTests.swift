import Foundation
import OffsiderCore
import Testing
@testable import Offsider

@Suite("boot report")
@MainActor
struct BootReportTests {
    static let pinLocked = AwakeReading(screen: .on, lockScreen: .secure, credential: "pin", userUnlocked: false, memTotalKB: 4_000_000)
    static let unlocked = AwakeReading(screen: .on, lockScreen: .hidden, credential: "none", userUnlocked: true, memTotalKB: 6_149_664)

    static func ledger() throws -> UnlockAttemptLedger {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("offsider-boot-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return UnlockAttemptLedger(root: root)
    }

    @Test("JSON keys come in the documented order, with explicit nulls and no error on success")
    func keyOrder() throws {
        let report = BootReport(
            avd: "Offsider_E2E_Pixel_9", serial: "emulator-5554", alreadyRunning: true, grpc: true, logPath: nil, memoryMB: 6005, ignored: [],
            bootedBy: ProcessStamp(pid: 4242, startedAt: Date(timeIntervalSince1970: 1_790_000_000)), lock: LockReport(Self.unlocked, savedCode: false, lastAttemptFailed: false)
        )
        #expect(report.jsonLine() == #"{"version":1,"ok":true,"avd":"Offsider_E2E_Pixel_9","serial":"emulator-5554","alreadyRunning":true,"grpc":true,"logPath":null,"memoryMB":6005,"ignored":[],"bootedBy":{"pid":4242,"startedAt":"2026-09-21T14:13:20Z"},"lock":{"type":"none","savedCode":false,"lastAttemptFailed":false,"userUnlocked":true,"screen":"on","lockScreen":"hidden"},"exitCode":0,"error":null}"#)
    }

    @Test("an unreadable state gives null lock fields")
    func unreadableLock() throws {
        let lock = Boot.lockReport(nil, key: "X", store: MemoryUnlockCodeStore(), ledger: try Self.ledger())
        #expect(lock == LockReport(type: nil, savedCode: false, lastAttemptFailed: false, userUnlocked: nil, screen: nil, lockScreen: nil))
        #expect(BootReport.firstUnlockFailure(avd: "X", serial: "emulator-5554", alreadyRunning: false, reading: nil, lock: lock) == nil)
    }

    @Test("a PIN device waiting for its first unlock fails as device_locked naming the serial, with ok false and exit 7")
    func firstUnlockFailure() throws {
        let lock = Boot.lockReport(Self.pinLocked, key: "Pixel_PIN", store: MemoryUnlockCodeStore(), ledger: try Self.ledger())
        let failure = try #require(BootReport.firstUnlockFailure(avd: "Pixel_PIN", serial: "emulator-5560", alreadyRunning: false, reading: Self.pinLocked, lock: lock))
        #expect(failure.message == "Pixel_PIN booted as emulator-5560 but is waiting for its first unlock (PIN); apps cannot start until it is unlocked.")
        var report = BootReport(avd: "Pixel_PIN", serial: "emulator-5560", alreadyRunning: false, grpc: true, logPath: "/tmp/x.log", memoryMB: 3906, ignored: [], lock: lock)
        report.error = ErrorPayload(reason: .deviceLocked, message: failure.message, hint: failure.hint)
        let object = try #require(try JSONSerialization.jsonObject(with: Data(report.jsonLine().utf8)) as? [String: Any])
        #expect(object["ok"] as? Bool == false)
        #expect(object["exitCode"] as? Int == 7)
        #expect((object["error"] as? [String: Any])?["reason"] as? String == "device_locked")
        #expect((object["lock"] as? [String: Any])?["userUnlocked"] as? Bool == false)
    }

    @Test("the hint asks to save a code, to type the saved one, or says the saved one failed")
    func hintChoice() throws {
        let store = MemoryUnlockCodeStore()
        let ledger = try Self.ledger()
        let none = Boot.lockReport(Self.pinLocked, key: "Pixel_PIN", store: store, ledger: ledger)
        #expect(none.savedCode == false)
        #expect(none.unlockHint(deviceID: "emulator-5560").contains("offsider unlock-code set --device emulator-5560"))

        store.codes["Pixel_PIN"] = try #require(UnlockCode("1234"))
        let saved = Boot.lockReport(Self.pinLocked, key: "Pixel_PIN", store: store, ledger: ledger)
        #expect(saved.savedCode)
        #expect(saved.unlockHint(deviceID: "emulator-5560").hasPrefix("Run `offsider wake --unlock --device emulator-5560`"))

        try ledger.recordFailure("Pixel_PIN")
        let failed = Boot.lockReport(Self.pinLocked, key: "Pixel_PIN", store: store, ledger: ledger)
        #expect(failed.lastAttemptFailed)
        #expect(failed.unlockHint(deviceID: "emulator-5560").hasPrefix("The saved code failed last time"))
    }

    @Test("a device with no credential never reads the Keychain")
    func noCredentialSkipsKeychain() throws {
        let store = MemoryUnlockCodeStore()
        store.codes["X"] = try #require(UnlockCode("1234"))
        #expect(Boot.lockReport(Self.unlocked, key: "X", store: store, ledger: try Self.ledger()).savedCode == false)
    }

    @Test("an unlocked device with its lock screen up gets a wake note, and little RAM a warning")
    func notes() {
        let showing = AwakeReading(screen: .on, lockScreen: .swipe, credential: "none", userUnlocked: true, memTotalKB: 2_000_000)
        #expect(BootReport.screenNote(avd: "X", serial: "emulator-5554", reading: showing) == "Note: X is on, swipe lock screen showing; run `offsider wake --device emulator-5554` before sending input.")
        #expect(BootReport.screenNote(avd: "X", serial: "emulator-5554", reading: Self.unlocked) == nil)
        #expect(BootReport.memoryNote(avd: "X", reading: showing) == "Warning: X has 1.9 GB of RAM, which is tight for a React Native debug build. Close it, then run `offsider boot X --memory 4096`.")
        #expect(BootReport.memoryNote(avd: "X", reading: Self.unlocked) == nil)
        let boundary = AwakeReading(screen: .on, lockScreen: .hidden, memTotalKB: BootReport.lowMemoryKB)
        #expect(BootReport.memoryNote(avd: "X", reading: boundary) == nil)
    }
}
