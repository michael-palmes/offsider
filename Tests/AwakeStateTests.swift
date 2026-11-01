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
        #expect(DeviceName.android(serial: "ZY22FAKE01", listed: "moto g", maker: "motorola") == "Motorola moto g (ZY22FAKE01)")
        #expect(DeviceName.android(serial: "emulator-5556", listed: "Offsider_E2E", maker: "Google") == "Offsider_E2E (emulator-5556)")
        #expect(DeviceName.android(serial: "ZY22FAKE01", listed: "ZY22FAKE01", maker: nil) == "ZY22FAKE01")
        #expect(DeviceName.label(maker: "samsung\n", model: "SM F000B") == "Samsung SM F000B")
        #expect(DeviceName.label(maker: "Google", model: "Google Pixel 9") == "Google Pixel 9")
        #expect(DeviceName.label(maker: "", model: "moto g") == "moto g")
        #expect(DeviceName.display("Offsider_E2E", label: nil) == "Offsider_E2E")
    }

    static let at = Date(timeIntervalSince1970: 1_790_000_000)
    static let utc = TimeZone(identifier: "UTC")!

    static func markerPath(_ device: String, root: String) -> String {
        ((root as NSString).appendingPathComponent(UnlockAttemptLedger.directoryName) as NSString).appendingPathComponent("device-\(device).failed")
    }

    /// Makes the ledger's directory and writes what an earlier version, or something else, left at the marker's path.
    static func plantMarker(_ contents: Data, device: String, root: String) throws -> String {
        let ledger = UnlockAttemptLedger(root: root)
        try ledger.record(UnlockAttemptRecord(outcome: .started, at: nil, credential: nil), for: device)
        let path = markerPath(device, root: root)
        try FileManager.default.removeItem(atPath: path)
        #expect(FileManager.default.createFile(atPath: path, contents: contents))
        return path
    }

    @Test("an attempt's outcome, time and lock type are remembered per device until cleared, and no code is written")
    func ledger() throws {
        let root = try makePrivateLockRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let ledger = UnlockAttemptLedger(root: root)
        let rejected = UnlockAttemptRecord(outcome: .rejected, at: Self.at, credential: "pin")

        try ledger.record(rejected, for: "ZY22FAKE01")
        #expect(ledger.lastAttempt("ZY22FAKE01") == rejected)
        #expect(ledger.lastAttempt("Offsider_E2E") == nil)
        let written = try #require(FileManager.default.contents(atPath: Self.markerPath("ZY22FAKE01", root: root)))
        #expect(try #require(JSONSerialization.jsonObject(with: written) as? [String: String]) == ["outcome": "rejected", "at": "2026-09-21T14:13:20Z", "credential": "pin"])
        ledger.clear("ZY22FAKE01")
        #expect(ledger.lastAttempt("ZY22FAKE01") == nil)
    }

    @Test("a marker with no outcome still blocks, as an attempt with no result dated by the file", arguments: [
        Data(), Data("not json".utf8), Data(#"{"outcome":"later"}"#.utf8), Data(repeating: 0x20, count: 2048),
    ])
    func oldMarker(contents: Data) throws {
        let root = try makePrivateLockRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let path = try Self.plantMarker(contents, device: "ZY22FAKE01", root: root)
        try FileManager.default.setAttributes([.modificationDate: Self.at], ofItemAtPath: path)

        #expect(UnlockAttemptLedger(root: root).lastAttempt("ZY22FAKE01") == UnlockAttemptRecord(outcome: .started, at: Self.at, credential: nil))
    }

    @Test("something other than a file at the marker's path still blocks, and is never followed")
    func strangeMarker() throws {
        let root = try makePrivateLockRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let path = try Self.plantMarker(Data(), device: "ZY22FAKE01", root: root)
        try FileManager.default.removeItem(atPath: path)
        let elsewhere = (root as NSString).appendingPathComponent("elsewhere")
        try Data(#"{"outcome":"rejected"}"#.utf8).write(to: URL(fileURLWithPath: elsewhere))
        try FileManager.default.createSymbolicLink(atPath: path, withDestinationPath: elsewhere)

        #expect(UnlockAttemptLedger(root: root).lastAttempt("ZY22FAKE01")?.outcome == .started)
    }

    @Test("an unlocked device settles an attempt with no result, but a rejected code stays known wrong")
    func clearUnfinished() throws {
        let root = try makePrivateLockRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let ledger = UnlockAttemptLedger(root: root)

        try ledger.record(UnlockAttemptRecord(outcome: .started, at: Self.at, credential: "pin"), for: "ZY22FAKE01")
        ledger.clearUnfinished("ZY22FAKE01")
        #expect(ledger.lastAttempt("ZY22FAKE01") == nil)

        try ledger.record(UnlockAttemptRecord(outcome: .rejected, at: Self.at, credential: "pin"), for: "ZY22FAKE01")
        ledger.clearUnfinished("ZY22FAKE01")
        #expect(ledger.lastAttempt("ZY22FAKE01")?.outcome == .rejected)
    }

    @Test("the message puts the cause first, then the one fix, then why Offsider won't retry", arguments: [
        ("pin", "The saved PIN is wrong: moto g (ZY22FAKE01) stayed locked after Offsider typed it on 21 Sep at 14:13.\nSave the right one: `offsider unlock-code set --device ZY22FAKE01`\nOffsider won't type it again: repeated wrong PINs can lock a phone out."),
        ("password", "The saved password is wrong: moto g (ZY22FAKE01) stayed locked after Offsider typed it on 21 Sep at 14:13.\nSave the right one: `offsider unlock-code set --device ZY22FAKE01`\nOffsider won't type it again: repeated wrong passwords can lock a phone out."),
        (nil, "The saved code is wrong: moto g (ZY22FAKE01) stayed locked after Offsider typed it on 21 Sep at 14:13.\nSave the right one: `offsider unlock-code set --device ZY22FAKE01`\nOffsider won't type it again: repeated wrong codes can lock a phone out."),
    ] as [(String?, String)])
    func wrongMessage(credential: String?, expected: String) {
        let record = UnlockAttemptRecord(outcome: .rejected, at: Self.at, credential: credential)
        #expect(record.message(name: "moto g (ZY22FAKE01)", device: "ZY22FAKE01", timeZone: Self.utc) == expected)
    }

    @Test("an attempt with no result says Offsider can't tell, not that the code is wrong")
    func unknownMessage() {
        let record = UnlockAttemptRecord(outcome: .started, at: Self.at, credential: "pin")
        #expect(record.message(name: "moto g (ZY22FAKE01)", device: "ZY22FAKE01", timeZone: Self.utc) == "Offsider can't tell if the saved PIN is right: it has no result for its unlock of moto g (ZY22FAKE01) on 21 Sep at 14:13.\nSave it again: `offsider unlock-code set --device ZY22FAKE01`\nOffsider won't type it until then: repeated wrong PINs can lock a phone out.")
    }

    @Test("a device key with a path in it stays inside the ledger directory")
    func ledgerKeys() throws {
        let root = try makePrivateLockRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try UnlockAttemptLedger(root: root).record(UnlockAttemptRecord(outcome: .started, at: Self.at, credential: nil), for: "../escape")

        let files = try FileManager.default.contentsOfDirectory(atPath: (root as NSString).appendingPathComponent(UnlockAttemptLedger.directoryName))
        #expect(files == ["device-.._escape.failed"])
    }
}
