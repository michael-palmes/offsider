import Foundation
import OffsiderCore
import Testing

@Suite("list-devices order and next step")
struct DeviceListOrderTests {
    static func row(_ id: String, _ platform: DevicePlatform, _ state: String, _ kind: DeviceKind, avd: String? = nil) -> DeviceSummary {
        DeviceSummary(id: id, platform: platform, state: state, name: id, osVersion: nil, deviceType: nil, kind: kind, avd: avd)
    }

    @Test("booted rows come first within each platform, and platforms keep their order")
    func bootedFirst() {
        let rows = [
            Self.row("SIM-A", .ios, "Shutdown", .simulator),
            Self.row("SIM-B", .ios, "Booted", .simulator),
            Self.row("Pixel", .android, "Shutdown", .avd, avd: "Pixel"),
            Self.row("emulator-5554", .android, "Booting", .emulator),
            Self.row("emulator-5556", .android, "Booted", .emulator),
        ]
        #expect(DeviceListOrder.sorted(rows).map(\.id) == ["SIM-B", "SIM-A", "emulator-5556", "emulator-5554", "Pixel"])
        #expect(DeviceListOrder.running(rows).map(\.id) == ["SIM-B", "emulator-5554", "emulator-5556"])
    }

    @Test("one booted simulator or emulator is the next step; a booted phone never is")
    func nextStep() {
        let phone = Self.row("SERIAL123", .android, "Booted", .physical)
        let emulator = Self.row("emulator-5554", .android, "Booted", .emulator)
        #expect(DeviceListOrder.nextStep([phone, emulator], currentDefault: nil) == "Next: export OFFSIDER_DEVICE=emulator-5554")
        #expect(DeviceListOrder.nextStep([emulator], currentDefault: "emulator-5554") == "Next: offsider doctor --device emulator-5554")
        #expect(DeviceListOrder.nextStep([phone], currentDefault: nil) == nil)
        #expect(DeviceListOrder.nextStep([emulator, Self.row("SIM-B", .ios, "Booted", .simulator)], currentDefault: nil) == nil)
    }

    @Test("with nothing booted, the next step boots the first AVD or simulator")
    func bootSuggestion() {
        #expect(DeviceListOrder.nextStep([Self.row("Pixel", .android, "Shutdown", .avd, avd: "Pixel")], currentDefault: nil) == "Next: offsider boot Pixel")
        #expect(DeviceListOrder.nextStep([Self.row("SIM-A", .ios, "Shutdown", .simulator)], currentDefault: nil) == "Next: offsider boot SIM-A")
        #expect(DeviceListOrder.nextStep([], currentDefault: nil) == nil)
    }

    @Test("doctor without --device suggests the one booted device to check next")
    func doctorNextStep() {
        let xcode = XcodeSummary(developerDir: nil, version: nil, build: nil, coreSimulator: nil)
        let simulator = BootedSimulator(udid: "SIM-B", name: "iPhone", osVersion: "iOS 27.0", deviceType: "iPhone")
        let one = DoctorReport(offsiderVersion: "0", udid: nil, xcode: xcode, booted: [simulator], checks: [])
        #expect(one.nextStep == "Next: offsider doctor --device SIM-B")
        let android = AndroidSummary(
            sdkRoot: "/sdk", sdkSource: "ANDROID_HOME", adbPath: "/sdk/platform-tools/adb", adbVersion: nil, adbServer: nil, adbServerVersion: nil, emulatorRevision: nil,
            devices: [AndroidDeviceRow(serial: "emulator-5554", kind: "emulator", state: "device", avd: "Pixel", apiLevel: 36)]
        )
        #expect(DoctorReport(offsiderVersion: "0", udid: nil, xcode: xcode, booted: [simulator], android: android, checks: []).nextStep == nil)
        #expect(DoctorReport(offsiderVersion: "0", udid: nil, xcode: xcode, booted: [], android: android, checks: []).nextStep == "Next: offsider doctor --device emulator-5554")
        let named = DoctorReport(offsiderVersion: "0", udid: "SIM-B", device: DoctorDevice(id: "SIM-B", platform: "ios", name: nil, kind: "simulator"), xcode: xcode, booted: [simulator], checks: [])
        #expect(named.nextStep == nil)
    }

    @Test("a simulator is matched by UDID or by a name only one simulator has")
    func simulatorMatch() {
        let udid = UUID().uuidString
        let a = SimulatorBootCandidate(udid: udid, name: "iPhone 17", state: "Shutdown", osVersion: "iOS 27.0")
        let b = SimulatorBootCandidate(udid: UUID().uuidString, name: "iPhone 17", state: "Shutdown", osVersion: "iOS 26.4")
        let c = SimulatorBootCandidate(udid: UUID().uuidString, name: "iPad Pro", state: "Shutdown", osVersion: "iOS 27.0")
        #expect(SimulatorBootTarget.match(udid.lowercased(), among: [a, b, c]) == .one(a))
        #expect(SimulatorBootTarget.match("ipad pro", among: [a, b, c]) == .one(c))
        #expect(SimulatorBootTarget.match("iPhone 17", among: [a, b, c]) == .several([a, b]))
        #expect(SimulatorBootTarget.match("Pixel", among: [a, b, c]) == .none)
        #expect(SimulatorBootTarget.ambiguity("iPhone 17", [a, b]).contains(b.udid))
    }
}
