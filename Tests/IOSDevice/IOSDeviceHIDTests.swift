import Foundation
import OffsiderCore
@testable import OffsiderIOSDevice
import Testing
import XPC

@Suite("Device DTUHID messages")
struct DeviceDTUHIDMessageTests {
    @Test("a device event drops a false isBarrier and keeps a barrier's true one")
    func forDevice() {
        let event = DTUHIDMessage.button(usagePage: 0x0C, usage: 0x40, state: .down)
        guard case .dictionary(let fields) = DTUHIDMessage.forDevice(event) else { Issue.record("not a dictionary"); return }
        #expect(fields["isBarrier"] == nil)
        #expect(fields["messageType"] == .string("IndigoButtonEvent"))
        #expect(DTUHIDMessage.forDevice(DTUHIDMessage.barrier(service: DTUHIDMessage.buttonService)) == DTUHIDMessage.barrier(service: DTUHIDMessage.buttonService))
    }

    @Test("a key carries its usage and a 1-based state on the keyboard feature")
    func keyboard() {
        #expect(DTUHIDMessage.keyboard(usage: 4, state: .down) == .dictionary([
            "messageType": .string("IndigoKeyboardButtonEvent"),
            "isBarrier": .bool(false),
            "featureIdentifier": .string("com.apple.coredevice.feature.remote.hid.keyboard"),
            "payload": .dictionary(["usageCode": .uint(4), "state": .uint(1)]),
        ]))
    }

    @Test("a button carries its usage page and code on the button feature; up is 2")
    func button() {
        #expect(DTUHIDMessage.button(usagePage: 0x0C, usage: 0x40, state: .up) == .dictionary([
            "messageType": .string("IndigoButtonEvent"),
            "isBarrier": .bool(false),
            "featureIdentifier": .string("com.apple.coredevice.feature.remote.hid.button"),
            "payload": .dictionary(["usagePage": .uint(0x0C), "usageCode": .uint(0x40), "state": .uint(2)]),
        ]))
    }

    @Test("every envelope can name the socket it travels on")
    func serviceOverride() {
        let digitizer = DTUHIDMessage.digitizerService
        for message in [
            DTUHIDMessage.keyboard(usage: 4, state: .down, service: digitizer),
            DTUHIDMessage.button(usagePage: 0x0C, usage: 0x40, state: .down, service: digitizer),
            DTUHIDMessage.touch(x: 0.5, y: 0.5, phase: .start, target: 0, service: digitizer),
            DTUHIDMessage.barrier(service: digitizer),
        ] {
            guard case let .dictionary(fields) = message else { Issue.record("not a dictionary"); continue }
            #expect(fields["featureIdentifier"] == .string(digitizer))
        }
    }
}

@Suite("Device panel")
struct IOSDevicePanelTests {
    static func displays(width: Int, height: Int, scale: Int, current: String) -> Data {
        Data("""
        {"result": {"displays": [{"displayId": 1, "primary": true, "nativeSize": [\(width), \(height)], "pointScale": \(scale),
          "currentOrientation": "\(current)", "nativeOrientation": "rot270", "type": {"integrated": {}}}]}}
        """.utf8)
    }

    @Test("an iPhone's panel is its native pixels over the point scale")
    func phone() throws {
        let panel = try #require(IOSDevicePanel.parse(displaysJSON: try IOSDeviceFixtures.data("devicectl-info-displays.json")))
        #expect(panel == IOSDevicePanel(width: 430, height: 932, scale: 3, orientation: .portrait))
        let centre = panel.fraction(x: panel.panelPoint(x: 215, y: 466).x, y: panel.panelPoint(x: 215, y: 466).y)
        #expect(centre == (x: 0.5, y: 0.5))
    }

    @Test("an iPad Pro's panel is landscape-native, and a UI on its native axes maps straight through")
    func iPad() throws {
        let panel = try #require(IOSDevicePanel.parse(displaysJSON: Self.displays(width: 2752, height: 2064, scale: 2, current: "rot0")))
        #expect(panel.width == 1376)
        #expect(panel.height == 1032)
        #expect(panel.uiWidth == 1376)
        let point = panel.panelPoint(x: 344, y: 774)
        #expect(panel.fraction(x: point.x, y: point.y) == (x: 0.25, y: 0.75))
    }

    @Test("an iPad at More Space is measured in the points of its 3200 x 2400 bounds, so the UI's centre is the touchscreen's")
    func iPadMoreSpace() throws {
        let json = Data("""
        {"result": {"displays": [{"displayId": 1, "primary": true, "bounds": [[0, 0], [3200, 2400]], "nativeSize": [2752, 2064], "pointScale": 2,
          "currentOrientation": "rot0", "nativeOrientation": "rot270", "type": {"integrated": {}}}]}}
        """.utf8)
        let panel = try #require(IOSDevicePanel.parse(displaysJSON: json))
        #expect(panel == IOSDevicePanel(width: 1600, height: 1200, scale: 2, orientation: .portrait))
        #expect(panel.touchscreenPoint(x: 800, y: 600) == (32768, 32768))
    }

    @Test("a UI turned a quarter on the panel swaps its size, keeps its centre and moves its corner", arguments: ["rot90", "rot270"])
    func turned(current: String) throws {
        let panel = try #require(IOSDevicePanel.parse(displaysJSON: Self.displays(width: 1290, height: 2796, scale: 3, current: current)))
        #expect(panel.orientation.isLandscape)
        #expect(panel.uiWidth == 932)
        #expect(panel.uiHeight == 430)
        let centre = panel.panelPoint(x: 466, y: 215)
        #expect(panel.fraction(x: centre.x, y: centre.y) == (x: 0.5, y: 0.5))
        let corner = panel.panelPoint(x: 0, y: 0)
        let fraction = panel.fraction(x: corner.x, y: corner.y)
        #expect([0.0, 1.0].contains(fraction.x) && [0.0, 1.0].contains(fraction.y))
        #expect(fraction != (x: 0, y: 0))
    }

    @Test("a reply without a size is unreadable")
    func unreadable() {
        #expect(IOSDevicePanel.parse(displaysJSON: Data(#"{"result": {"displays": [{"displayId": 1}]}}"#.utf8)) == nil)
    }
}

@Suite("CoreDevice version floor")
struct CoreDeviceVersionTests {
    @Test("HID needs CoreDevice 636 or later", arguments: [
        ("651.13.4", true), ("636", true), ("636.0.0", true), ("635.99", false), ("518.24", false),
    ])
    func floor(text: String, supported: Bool) throws {
        #expect(try #require(CoreDeviceVersion(text)).supportsHID == supported)
    }

    @Test("a version that is not dotted numbers is unreadable", arguments: ["", "651.x", "beta"])
    func unreadable(text: String) {
        #expect(CoreDeviceVersion(text) == nil)
    }

    @Test("the request version keeps every component and the original count")
    func xpcShape() throws {
        let object = try #require(CoreDeviceVersion("651.13.4")).xpcObject
        #expect(String(cString: try #require(xpc_dictionary_get_string(object, "stringValue"))) == "651.13.4")
        #expect(xpc_dictionary_get_int64(object, "originalComponentsCount") == 3)
        let components = try #require(xpc_dictionary_get_value(object, "components"))
        #expect((0..<xpc_array_get_count(components)).map { xpc_array_get_uint64(components, $0) } == [651, 13, 4])
    }
}

@Suite("CoreDevice HID errors")
struct CoreDeviceHIDErrorTests {
    static func error(domain: String, code: Int64, description: String? = nil, underlying: xpc_object_t? = nil) -> xpc_object_t {
        let error = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_string(error, "domain", domain)
        xpc_dictionary_set_int64(error, "code", code)
        let info = xpc_dictionary_create(nil, nil, 0)
        if let description { xpc_dictionary_set_string(info, "NSLocalizedDescription", description) }
        if let underlying { xpc_dictionary_set_value(info, "NSUnderlyingError", underlying) }
        xpc_dictionary_set_value(error, "userInfo", info)
        return error
    }

    @Test("RemotePairingError 1016 beneath a CoreDevice error means locked: device_locked, exit 7, nothing sent")
    func lockedSocket() throws {
        let nested = Self.error(domain: "com.apple.dt.CoreDeviceError", code: 1, description: "Failed to create service socket",
                                underlying: Self.error(domain: "RemotePairing.RemotePairingError", code: 1016))
        let info = try #require(CoreDeviceErrorInfo(xpc: nested))
        #expect(info.isLocked)
        let failure = IOSDeviceError.serviceSocket(info, feature: DTUHIDMessage.digitizerService, name: "iPad", udid: IOSDeviceFixtures.iPad, sent: false)
        #expect(failure.reason == .deviceLocked)
        #expect(failure.exitCode == .deviceUnavailable)
        #expect(failure.message.contains("Unlock"))
        #expect(failure.message.contains("no input was sent"))
        #expect(failure.hint == "offsider doctor --device \(IOSDeviceFixtures.iPad)")
    }

    @Test("a disk image without the HID service asks for Xcode 27")
    func unsupportedFeature() {
        let info = CoreDeviceErrorInfo(domain: "com.apple.dt.CoreDeviceError", code: 1, description: "Create Service Socket is not supported by this device")
        let failure = IOSDeviceError.serviceSocket(info, feature: DTUHIDMessage.digitizerService, name: "iPad", udid: IOSDeviceFixtures.iPad, sent: false)
        #expect(failure.reason == .xcodeTooOld)
        #expect(failure.message.contains("Install Xcode 27 for HID input"))
    }

    @Test("a refused barrier on an unlocked device means UI Automation is off; on a locked one, locked")
    func barrier() {
        let unlocked = IOSDeviceError.barrierRefused(CoreDeviceErrorInfo(domain: "dtuhidd", code: 3), name: "iPad", udid: IOSDeviceFixtures.iPad, sent: false)
        #expect(unlocked.reason == .uiAutomationOff)
        #expect(unlocked.message.contains("Settings > Developer > UI Automation"))
        let locked = IOSDeviceError.barrierRefused(
            CoreDeviceErrorInfo(domain: "x", code: 1, underlying: [CoreDeviceErrorInfo(domain: "RemotePairingError", code: 1016)]), name: "iPad", udid: IOSDeviceFixtures.iPad, sent: false
        )
        #expect(locked.reason == .deviceLocked)
    }

    @Test("after earlier input, locked, UI Automation off, a down tunnel and an unopened feature never claim nothing was sent")
    func afterEarlierInput() {
        let failures = [
            IOSDeviceError.serviceSocket(CoreDeviceErrorInfo(domain: "x", code: 1, underlying: [CoreDeviceErrorInfo(domain: "RemotePairingError", code: 1016)]),
                                         feature: DTUHIDMessage.keyboardService, name: "iPad", udid: IOSDeviceFixtures.iPad, sent: true),
            IOSDeviceError.serviceSocket(CoreDeviceErrorInfo(domain: "com.apple.dt.CoreDeviceError", code: 4000),
                                         feature: DTUHIDMessage.keyboardService, name: "iPad", udid: IOSDeviceFixtures.iPad, sent: true),
            IOSDeviceError.serviceSocket(CoreDeviceErrorInfo(domain: "x", code: 9, description: "nope"),
                                         feature: DTUHIDMessage.keyboardService, name: "iPad", udid: IOSDeviceFixtures.iPad, sent: true),
            IOSDeviceError.barrierRefused(CoreDeviceErrorInfo(domain: "dtuhidd", code: 3), name: "iPad", udid: IOSDeviceFixtures.iPad, sent: true),
        ]
        for failure in failures {
            #expect(!failure.message.localizedCaseInsensitiveContains("no input was sent"), "\(failure.message)")
            #expect(failure.message.localizedCaseInsensitiveContains("may have reached it"), "\(failure.message)")
        }
    }

    @Test("a reply carrying an error is a refusal; any other dictionary is an answer")
    func replies() {
        let refused = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_value(refused, "error", Self.error(domain: "dtuhidd", code: 2, description: "UI Automation is disabled"))
        #expect(DTUHIDReply(xpc: refused) == .refused(CoreDeviceErrorInfo(domain: "dtuhidd", code: 2, description: "UI Automation is disabled")))
        let text = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_string(text, "errorDescription", "refused")
        #expect(DTUHIDReply(xpc: text) == .refused(CoreDeviceErrorInfo(domain: "errorDescription", code: 0, description: "refused")))
        let answer = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_bool(answer, "isBarrier", true)
        #expect(DTUHIDReply(xpc: answer) == .answered)
    }
}
