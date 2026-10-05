import Foundation
import OffsiderCore
@testable import OffsiderIOSDevice
import Testing
import XPC

@Suite("UniversalHID reports")
struct UniversalHIDReportTests {
    @Test("a touchscreen contact is report 0x09, 58 bytes, with little-endian axes and a 48-bit timestamp at byte 44")
    func touchscreenContact() {
        let report = [UInt8](UniversalHIDReport.touchscreen(x: 0x1234, y: 0xABCD, state: .contact, timestamp: 0x1122_3344_5566_7788))
        #expect(report.count == 58)
        #expect(Array(report[0..<8]) == [0x09, 0x01, 0x05, 0xC2, 0x34, 0x12, 0xCD, 0xAB])
        #expect(report[8..<40].allSatisfy { $0 == 0 })
        #expect(Array(report[40..<44]) == [0x02, 0x00, 0x00, 0x00])
        #expect(Array(report[44..<50]) == [0x88, 0x77, 0x66, 0x55, 0x44, 0x33])
        #expect(report[50..<58].allSatisfy { $0 == 0 })
    }

    @Test("a release differs from a contact only in its state byte")
    func touchscreenRelease() {
        let contact = [UInt8](UniversalHIDReport.touchscreen(x: 100, y: 200, state: .contact, timestamp: 7))
        let release = [UInt8](UniversalHIDReport.touchscreen(x: 100, y: 200, state: .release, timestamp: 7))
        #expect(release[3] == 0x02)
        #expect(contact.indices.filter { contact[$0] != release[$0] } == [3])
    }

    @Test("a keyboard report sets bit usage % 8 of byte 1 + usage / 8, so Command is byte 29 bit 3")
    func keyboardBitmap() {
        let report = [UInt8](UniversalHIDReport.keyboard(pressedUsages: [0x04, 0xE3]))
        #expect(report.count == 39)
        #expect(report[0] == 0x01)
        #expect(report[1] == 0x10)
        #expect(report[29] == 0x08)
        #expect(report.indices.filter { $0 > 0 && report[$0] != 0 } == [1, 29])
    }

    @Test("an empty keyboard report releases every key, and usages past the bitmap are left out")
    func keyboardRelease() {
        let report = [UInt8](UniversalHIDReport.keyboard(pressedUsages: [0xF0, 0xFF], timestamp: 0x0102_0304_0506))
        #expect(report[1..<31].allSatisfy { $0 == 0 })
        #expect(Array(report[31..<37]) == [0x06, 0x05, 0x04, 0x03, 0x02, 0x01])
        #expect(report[37] == 0 && report[38] == 0)
    }

    @Test("an axis fraction spans 0 to 65535 and clamps what falls off the panel")
    func axis() {
        #expect(UniversalHIDReport.axis(0) == 0)
        #expect(UniversalHIDReport.axis(1) == 65535)
        #expect(UniversalHIDReport.axis(0.5) == 32768)
        #expect(UniversalHIDReport.axis(-0.2) == 0)
        #expect(UniversalHIDReport.axis(1.4) == 65535)
        #expect(UniversalHIDReport.axis(.nan) == 0)
    }
}

@Suite("UniversalHID touchscreen mapping")
struct UniversalHIDMappingTests {
    let iPad = IOSDevicePanel(width: 1376, height: 1032, scale: 2, orientation: .portrait)

    @Test("the Developer Mode row an iPad Pro 13-inch took the tap at maps to the report the device accepted")
    func iPadSettingsRow() {
        let point = iPad.touchscreenPoint(x: 397, y: 394)
        #expect(point.x == 40515 && point.y == 18908)
    }

    @Test("on a landscape-native panel x climbs from the UI's bottom edge and y runs left to right")
    func landscapeCorners() {
        #expect(iPad.touchscreenPoint(x: 0, y: 0) == (65535, 0))
        #expect(iPad.touchscreenPoint(x: 0, y: 1032) == (0, 0))
        #expect(iPad.touchscreenPoint(x: 1376, y: 1032) == (0, 65535))
    }

    @Test("a portrait-native panel keeps its axes")
    func portraitPanel() {
        let phone = IOSDevicePanel(width: 402, height: 874, scale: 3, orientation: .portrait)
        #expect(phone.touchscreenPoint(x: 201, y: 874) == (32768, 65535))
    }

    /// The iPad at Display Zoom "More Space": `nativeSize` gives 1376 x 1032 points, `bounds` 1600 x 1200 (here in the other order).
    let morePoints = IOSDevicePoints(width: 1200, height: 1600)

    @Test("measured in the UI's points, the UI's centre and far corner land on the touchscreen's centre and corner")
    func runnerBasis() {
        let panel = iPad.rebased(onPoints: morePoints)
        #expect(panel.width == 1600 && panel.height == 1200)
        #expect(panel.touchscreenPoint(x: 800, y: 600) == (32768, 32768))
        #expect(panel.touchscreenPoint(x: 1600, y: 1200) == (0, 65535))
        #expect(panel.touchscreenPoint(x: 400, y: 300) == (49151, 16384))
    }

    @Test("measured in nativeSize points, the same UI point lands past the centre")
    func nativeBasis() {
        #expect(iPad.rebased(onPoints: nil) == iPad)
        let native = iPad.touchscreenPoint(x: 800, y: 600)
        #expect(native.x == 27433 && native.y == 38102)
        #expect(native != iPad.rebased(onPoints: morePoints).touchscreenPoint(x: 800, y: 600))
    }

    @Test("a portrait-native panel takes the UI's points on its own axes")
    func portraitRebased() {
        let phone = IOSDevicePanel(width: 402, height: 874, scale: 3, orientation: .portrait).rebased(onPoints: IOSDevicePoints(width: 375, height: 812))
        #expect(phone.width == 375 && phone.height == 812)
        #expect(phone.touchscreenPoint(x: 187.5, y: 812) == (32768, 65535))
    }

    @Test("a broker touch on the rebased panel sends the touchscreen's centre for the UI's centre")
    func reportsOnRunnerBasis() throws {
        let reports = try DeviceSessionReports.touch([.touch(.down, x: 800, y: 600), .touch(.up, x: 800, y: 600)], panel: iPad.rebased(onPoints: morePoints))
        #expect(reports == [.touch(x: 32768, y: 32768, state: .contact), .touch(x: 32768, y: 32768, state: .release)])
    }
}

@Suite("UniversalHID messages")
struct UniversalHIDMessageTests {
    @Test("connectedServices is a Request with an empty payload case on the UniversalHID feature")
    func connectedServices() {
        #expect(UniversalHIDMessage.connectedServices() == .dictionary([
            "featureIdentifier": .string("com.apple.coredevice.feature.remote.universalhidservice"),
            "messageType": .string("Request"),
            "payload": .dictionary(["connectedServices": .dictionary([:])]),
        ]))
    }

    @Test("send carries the report as data and the surface as an unsigned ID")
    func send() {
        let report = Data([0x01, 0x02])
        #expect(UniversalHIDMessage.send(report, to: 512)["payload"] == .dictionary([
            "send": .dictionary(["_0": .data(report), "_1": .uint(512)]),
        ]))
    }

    @Test("createService wraps every stored property in a Codable type envelope and keeps the ID unsigned")
    func createKeyboardService() throws {
        let message = UniversalHIDMessage.createKeyboardService(id: 0x1_0000_2001)
        let descriptor = try #require(message["payload"]?["createService"]?["_0"])
        #expect(descriptor["_ServiceID"] == .uint(0x1_0000_2001))
        #expect(descriptor["PrimaryUsagePage"] == .uint(1) && descriptor["PrimaryUsage"] == .uint(6))
        #expect(descriptor["VendorID"] == .int(0x05AC))
        let storage = try #require(descriptor["_CoreDevice_codablePropertyStorage"])
        #expect(storage["UniversalControlVirtualService"] == .dictionary(["bool": .bool(true)]))
        #expect(storage["_ServiceID"] == .dictionary(["uint": .uint(0x1_0000_2001)]))
        #expect(storage["PrimaryUsagePage"] == .dictionary(["int": .int(1)]))
    }

    @Test("values survive XPC with ints and uints kept apart")
    func xpcRoundTrip() {
        let value = UniversalHIDMessage.createKeyboardService()
        #expect(UniversalHIDValue(xpc: value.xpcObject) == value)
    }
}

@Suite("UniversalHID surfaces")
struct UniversalHIDSurfaceTests {
    static func descriptor(_ id: UInt64, _ product: String, hint: String?, page: UInt64, usage: UInt64) -> UniversalHIDValue {
        var entries: [String: UniversalHIDValue] = [
            "_ServiceID": .uint(id), "Product": .string(product), "PrimaryUsagePage": .uint(page), "PrimaryUsage": .uint(usage),
            "_CoreDevice_codablePropertyStorage": .dictionary(["_ServiceID": .dictionary(["uint": .uint(id)])]),
        ]
        if let hint { entries["DeviceTypeHint"] = .string(hint) }
        return .dictionary(entries)
    }

    /// The iPad Pro 13-inch on iOS 27.0's reply, trimmed to the fields Offsider reads.
    static let reply = UniversalHIDValue.dictionary(["connectedServices": .array([
        descriptor(257, "CoreDevice touchscreen(nil)", hint: "Digitizer", page: 13, usage: 4),
        descriptor(512, "CoreDevice keyboard", hint: "Keyboard", page: 0, usage: 0),
        descriptor(1026, "CoreDevice mainScreenButtons", hint: nil, page: 11, usage: 1),
        descriptor(1280, "CoreDevice avpCustom", hint: nil, page: 65377, usage: 91),
        descriptor(1281, "CoreDevice touchscreenGesture", hint: "Trackpad", page: 1, usage: 2),
    ])])

    @Test("each descriptor becomes a surface with its ID and role, in reply order")
    func parse() {
        let surfaces = UniversalHIDSurface.parse(Self.reply)
        #expect(surfaces.map(\.id) == [257, 512, 1026, 1280, 1281])
        #expect(surfaces.map(\.role) == [.touchscreen, .keyboard, .buttons, .other, .trackpad])
        #expect(surfaces.first(.keyboard)?.product == "CoreDevice keyboard")
    }

    @Test("a reply without connectedServices lists no surfaces")
    func otherReply() {
        #expect(UniversalHIDSurface.parse(.dictionary(["serviceID": .uint(4)])).isEmpty)
    }
}

@Suite("UniversalHID replies")
struct UniversalHIDReplyTests {
    @Test("a dictionary reply is the answer, a dead connection is lost, and an error dictionary is a refusal")
    func outcomes() {
        let reply = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_uint64(reply, "serviceID", 9)
        #expect(UniversalHIDService.outcome(reply) == .reply(.dictionary(["serviceID": .uint(9)])))

        guard case .connectionLost = UniversalHIDService.outcome(XPC_ERROR_CONNECTION_INVALID) else {
            Issue.record("an XPC error is not a lost connection")
            return
        }

        let refusal = xpc_dictionary_create(nil, nil, 0)
        let error = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_string(error, "domain", "com.apple.dt.CoreDeviceError")
        xpc_dictionary_set_int64(error, "code", 1)
        xpc_dictionary_set_value(refusal, "error", error)
        #expect(UniversalHIDService.outcome(refusal) == .refused(CoreDeviceErrorInfo(domain: "com.apple.dt.CoreDeviceError", code: 1)))
    }
}
