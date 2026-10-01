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
}
