import Foundation
import OffsiderCore
import Testing

@Suite("Awake state and unlock codes")
struct AwakeStateTests {
    @Test("power sources name their bits in order and leave out unknown ones")
    func sources() {
        #expect(PowerSources(rawValue: 15).names == ["ac", "usb", "wireless", "dock"])
        #expect(PowerSources(rawValue: 2 | 32).names == ["usb"])
        #expect(PowerSources(rawValue: 3).summary == "AC and USB")
        #expect(PowerSources(rawValue: 15).summary == "AC, USB, wireless and dock")
    }

    @Test("stay awake keeps the screen on only while a chosen source charges and no policy caps the timeout")
    func staysAwake() {
        var reading = AwakeReading(screen: .on, lockScreen: .hidden, stayAwake: [.usb], charging: [.ac])
        #expect(!reading.staysAwake)
        reading.charging = [.usb]
        #expect(reading.staysAwake)
        reading.timeoutCappedByPolicy = true
        #expect(!reading.staysAwake)
    }

    @Test("screen timeouts read in the largest whole unit, and Int32.max reads as never")
    func timeouts() {
        let summaries = [1_800_000, 15_000, 3_600_000, 90_000, Int(Int32.max)].map {
            AwakeReading(screen: .on, lockScreen: .hidden, screenTimeoutMilliseconds: $0).screenTimeoutSummary
        }
        #expect(summaries == ["30 min", "15 s", "1 h", "90 s", "never"])
    }

    @Test("a code is 4 to 64 printable ASCII characters, and a PIN is 4 to 16 digits")
    func codeFormat() {
        #expect(UnlockCode("1234\n")?.isPIN == true)
        #expect(UnlockCode("pass word%s'1")?.isPIN == false)
        #expect(UnlockCode("12345678901234567")?.isPIN == false)
        for invalid in ["123", "", String(repeating: "a", count: 65), "pässword", "tab\there"] {
            #expect(UnlockCode(invalid) == nil, "\(invalid.count) characters")
        }
    }

    @Test("a code never prints its text")
    func codeWithheld() throws {
        let code = try #require(UnlockCode("8642"))
        var dumped = ""
        dump(code, to: &dumped)
        for text in ["\(code)", String(describing: code), String(reflecting: code), dumped] {
            #expect(!text.contains("8642"))
        }
    }

    @Test("a phone is named by maker and model, an emulator by its AVD name, each with its serial")
    func deviceNames() {
        #expect(DeviceName.android(serial: "ZY22FAKE01", listed: "moto g57", maker: "motorola") == "Motorola moto g57 (ZY22FAKE01)")
        #expect(DeviceName.android(serial: "emulator-5556", listed: "Offsider_E2E_Pixel_9", maker: "Google") == "Offsider_E2E_Pixel_9 (emulator-5556)")
        #expect(DeviceName.android(serial: "ZY22FAKE01", listed: "ZY22FAKE01", maker: nil) == "ZY22FAKE01")
        #expect(DeviceName.label(maker: "samsung\n", model: "SM F926B") == "Samsung SM F926B")
        #expect(DeviceName.label(maker: "Google", model: "Google Pixel 9") == "Google Pixel 9")
        #expect(DeviceName.label(maker: "", model: "moto g57") == "moto g57")
        #expect(DeviceName.display("Offsider_E2E_Pixel_9", label: nil) == "Offsider_E2E_Pixel_9")
    }

    @Test("a failed attempt is remembered per device until cleared")
    func ledger() throws {
        let root = try makePrivateLockRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let ledger = UnlockAttemptLedger(root: root)

        try ledger.recordFailure("ZY22FAKE01")
        #expect(ledger.hasFailed("ZY22FAKE01"))
        #expect(!ledger.hasFailed("Offsider_E2E_Pixel_9"))
        ledger.clear("ZY22FAKE01")
        #expect(!ledger.hasFailed("ZY22FAKE01"))
    }

    @Test("a device key with a path in it stays inside the ledger directory")
    func ledgerKeys() throws {
        let root = try makePrivateLockRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try UnlockAttemptLedger(root: root).recordFailure("../escape")

        let files = try FileManager.default.contentsOfDirectory(atPath: (root as NSString).appendingPathComponent(UnlockAttemptLedger.directoryName))
        #expect(files == ["device-.._escape.failed"])
    }
}
