import Foundation
import OffsiderCore
import Testing

@Suite("Device ID Classifier Tests")
struct DeviceIDClassifierTests {
    private let udid = "ABCDEF00-0000-4000-8000-00000000ABCD"

    @Test("blank IDs are empty", arguments: ["", "   ", "\n\t"])
    func blankIsEmpty(raw: String) {
        #expect(DeviceIDClassifier.classify(raw) == .empty)
    }

    @Test("a UUID is an iOS simulator in canonical uppercase, whatever the case typed")
    func uuidIsCanonicalIOS() {
        #expect(DeviceIDClassifier.classify(udid) == .iosSimulator(udid: udid))
        #expect(DeviceIDClassifier.classify(udid.lowercased()) == .iosSimulator(udid: udid))
        #expect(DeviceIDClassifier.classify("  \(udid.lowercased())\n") == .iosSimulator(udid: udid))
        #expect(DeviceIDClassifier.classify(udid).platform == .ios)
    }

    @Test("emulator-<port> is an Android emulator serial")
    func emulatorSerial() {
        #expect(DeviceIDClassifier.classify("emulator-5554") == .androidSerial(consolePort: 5554))
        #expect(DeviceIDClassifier.classify(" emulator-5556 ") == .androidSerial(consolePort: 5556))
        #expect(DeviceIDClassifier.classify("emulator-5554").platform == .android)
    }

    @Test("other names made of letters, digits, dots, underscores and hyphens are Android names", arguments: [
        "Pixel_9_API_37", "Offsider_E2E", "my.avd-2", "invalid", "emulator-", "emulator-55a4",
        "ABCDEF00-0000-4000-8000", "ABCDEF0000004000800000000000ABCD",
    ])
    func avdCandidate(raw: String) {
        #expect(DeviceIDClassifier.classify(raw) == .androidName(name: raw))
        #expect(DeviceIDClassifier.classify(raw).platform == .android)
    }

    @Test("a USB serial is an Android name the router resolves", arguments: ["R58M123ABC", "1A2B3C4D5E6F", "R58TEST0001"])
    func usbSerialIsName(raw: String) {
        #expect(DeviceIDClassifier.classify(raw) == .androidName(name: raw))
    }

    @Test("host:port and mDNS serials are network serials", arguments: [
        "192.168.1.5:5555", "localhost:5555", "[fe80::1]:5555", "adb-1A2B-xyz._adb-tls-connect._tcp", "adb-1A2B-xyz._adb._tcp",
    ])
    func networkSerial(raw: String) {
        #expect(DeviceIDClassifier.classify(raw) == .androidNetworkSerial(serial: raw))
        #expect(DeviceIDClassifier.classify(raw).platform == .android)
    }

    @Test("a phone serial is never classified as an emulator serial", arguments: ["R58TEST0001", "R58M123ABC", "emulator5554", "emulator-", "192.168.1.5:5555"])
    func phoneIsNeverEmulator(raw: String) {
        if case .androidSerial = DeviceIDClassifier.classify(raw) {
            Issue.record("\(raw) was classified as an emulator serial")
        }
    }

    @Test("anything else is unrecognised", arguments: ["iPhone 17 Pro", "host:port", "{ABCDEF00-0000-4000-8000-00000000ABCD}", "pixel/9"])
    func unrecognised(raw: String) {
        #expect(DeviceIDClassifier.classify(raw) == .unrecognised)
        #expect(DeviceIDClassifier.classify(raw).platform == nil)
    }
}
