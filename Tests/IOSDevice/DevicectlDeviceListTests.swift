import Foundation
import OffsiderIOSDevice
import Testing

@Suite("devicectl device list")
struct DevicectlDeviceListTests {
    @Test("an Xcode 27 listing keeps the physical iPhone and drops the watch and simulators")
    func xcode27Filters() throws {
        let list = try DevicectlDeviceList.parse(try IOSDeviceFixtures.data("devicectl-list-xcode27-connected.json"))
        #expect(list.coreDeviceVersion == "651.13.4")
        #expect(list.devices.map(\.udid) == [IOSDeviceFixtures.phone])
    }

    @Test("an Xcode 27 row reads properties first and the deprecated blocks for what only they carry")
    func xcode27Row() throws {
        let device = try #require(try DevicectlDeviceList.parse(try IOSDeviceFixtures.data("devicectl-list-xcode27-connected.json")).devices.first)
        #expect(device == DevicectlDevice(
            udid: IOSDeviceFixtures.phone,
            coreDeviceIdentifier: "00000000-0000-4000-8000-0000000000A1",
            marketingName: "iPhone 15 Pro Max",
            productType: "iPhone16,2",
            osVersion: "27.2",
            osBuild: "24B5089g",
            pairingState: "paired",
            transportType: "localNetwork",
            connectionState: "connected",
            tunnelState: "connected",
            developerModeStatus: "enabled",
            ddiServicesAvailable: true
        ))
        #expect(device.label == "Apple iPhone 15 Pro Max")
    }

    @Test("with the tunnel down the developer services read as unavailable")
    func xcode27Disconnected() throws {
        let device = try #require(try DevicectlDeviceList.parse(try IOSDeviceFixtures.data("devicectl-list-xcode27-disconnected.json")).devices.first)
        #expect(device.connectionState == "disconnected")
        #expect(device.tunnelState == "disconnected")
        #expect(device.ddiServicesAvailable == false)
    }

    @Test("an Xcode 26 listing has only the deprecated blocks and no reality, and both devices count")
    func xcode26() throws {
        let list = try DevicectlDeviceList.parse(try IOSDeviceFixtures.data("devicectl-list-xcode26.json"))
        #expect(list.devices.map(\.udid) == [IOSDeviceFixtures.phone, IOSDeviceFixtures.iPad])
        let phone = list.devices[0]
        #expect(phone.transportType == "wired")
        #expect(phone.connectionState == "disconnected")
        #expect(phone.osVersion == "26.0")
        #expect(phone.osBuild == "23A341")
        #expect(list.devices[1].pairingState == "unpaired")
        #expect(list.devices[1].developerModeStatus == "disabled")
    }

    @Test("the newer developer mode shape names the status by its one key")
    func developerModeObject() throws {
        let json = """
        {"info": {"outcome": "success", "version": "700.1"}, "result": {"devices": [
          {"properties": {"hardware": {"platform": "iOS", "reality": "physical", "udid": "00008140-0000000000000001"},
                          "connection": {"pairingState": "paired", "state": "connected", "transportType": "wired"},
                          "state": {"developerModeStatus": {"disabled": {}}}}}
        ]}}
        """
        let device = try #require(try DevicectlDeviceList.parse(Data(json.utf8)).devices.first)
        #expect(device.developerModeStatus == "disabled")
        #expect(device.transportType == "wired")
        #expect(device.ddiServicesAvailable == nil)
        #expect(device.label == "Apple iPhone or iPad")
    }

    @Test("details parse into the listing's row shape")
    func details() throws {
        let device = try #require(try DevicectlDeviceList.parseDetails(try IOSDeviceFixtures.data("devicectl-info-details.json")))
        #expect(device.udid == IOSDeviceFixtures.phone)
        #expect(device.ddiServicesAvailable == true)
        #expect(device.tunnelState == "connected")
    }

    @Test("lock state and backlight come from their own replies")
    func lockInfo() throws {
        #expect(DevicectlLockInfo.passcodeRequired(try IOSDeviceFixtures.data("devicectl-info-lockstate.json")) == true)
        #expect(DevicectlLockInfo.backlightOn(try IOSDeviceFixtures.data("devicectl-info-displays.json")) == false)
        #expect(DevicectlLockInfo.backlightOn(Data("{}".utf8)) == nil)
    }

    @Test("a failed outcome, missing devices or no JSON is a parse error", arguments: [
        #"{"info": {"outcome": "failed"}, "result": {"devices": []}}"#,
        #"{"info": {"outcome": "success"}, "result": {}}"#,
        "devicectl: not found",
        "{ broken",
    ])
    func malformed(text: String) {
        #expect(throws: DevicectlDeviceList.ParseError.self) { try DevicectlDeviceList.parse(Data(text.utf8)) }
    }

    @Test("text before the JSON is skipped")
    func leadingText() throws {
        let text = "Warning: something\n" + (try IOSDeviceFixtures.text("devicectl-list-xcode26.json"))
        #expect(try DevicectlDeviceList.parse(Data(text.utf8)).devices.count == 2)
    }
}
