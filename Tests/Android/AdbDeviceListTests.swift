import Foundation
import Testing
@testable import OffsiderAndroid

@Suite("adb device list")
struct AdbDeviceListTests {
    private static let listing = """
    emulator-5554          device product:sdk_gphone64_arm64 model:sdk_gphone64_arm64 device:emu64a transport_id:1
    emulator-5556          offline transport_id:3
    emulator-5558          unauthorized transport_id:4
    R5CT1234ABC            device usb:1-1 product:e3qxeea model:SM_S928B device:e3q transport_id:5
    192.168.1.5:5555       device product:x model:y device:z transport_id:6
    emulator-5560          recovery transport_id:7
    lonely

    """

    @Test("rows keep serial, state and properties; blank and malformed lines are skipped")
    func parsesRows() {
        let entries = AdbDeviceListParser.parse(Self.listing)

        #expect(entries.map(\.serial) == ["emulator-5554", "emulator-5556", "emulator-5558", "R5CT1234ABC", "192.168.1.5:5555", "emulator-5560"])
        #expect(entries.map(\.state) == [.device, .offline, .unauthorized, .device, .device, .other("recovery")])
        #expect(entries[0].properties["model"] == "sdk_gphone64_arm64")
        #expect(entries[0].properties["transport_id"] == "1")
    }

    @Test("only emulator serials have a console port")
    func consolePorts() {
        let entries = AdbDeviceListParser.parse(Self.listing)
        #expect(entries.map(\.consolePort) == [5554, 5556, 5558, nil, nil, 5560])
    }

    @Test("an empty listing has no rows")
    func emptyListing() {
        #expect(AdbDeviceListParser.parse("").isEmpty)
        #expect(AdbDeviceListParser.parse("\n\n").isEmpty)
    }

    @Test("a usb: property makes a USB device; the attached phone's real row is one")
    func usbKind() {
        let row = "R5CRFAKE03            device usb:1-2.4.1.3 product:f0ldxxx model:SM_F000B device:f0ld transport_id:22\n"
        #expect(AdbDeviceListParser.parse(row).map(\.kind) == [.usb])
        #expect(AdbDeviceListParser.parse(Self.listing)[3].kind == .usb)
    }

    @Test("a row without usb: is a network device, whatever its serial looks like")
    func networkKind() {
        let entries = AdbDeviceListParser.parse(Self.listing + "R58M123ABC device product:tokay model:Pixel_9 transport_id:8\nadb-1A2B-x._adb-tls-connect._tcp device usb:0 transport_id:9\n")
        #expect(entries[4].kind == .network)
        #expect(entries.first { $0.serial == "R58M123ABC" }?.kind == .network)
        #expect(entries.first { $0.serial.hasSuffix("._tcp") }?.kind == .network)
    }

    @Test("an unauthorised USB row keeps its kind, and only emulator rows are emulators")
    func unauthorisedKeepsKind() {
        let entries = AdbDeviceListParser.parse("1A2B3C4D5E6F unauthorized usb:1-2 transport_id:3\nemulator-5554 device transport_id:1\n")
        #expect(entries.map(\.kind) == [.usb, .emulator(consolePort: 5554)])
    }
}
