import Foundation
import OffsiderCore
@testable import OffsiderIOSDevice
import Testing
import XPC

@Suite("Device DTUHID messages")
struct DeviceDTUHIDMessageTests {
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

@Suite("Device input lowering")
struct DTUHIDLoweringTests {
    static let phone = IOSDevicePanel(width: 430, height: 932, scale: 3, orientation: .portrait)
    static let digitizer = DTUHIDMessage.digitizerService

    static func touch(_ x: Double, _ y: Double, _ phase: DTUHIDMessage.TouchPhase) -> DTUHIDStep {
        .send(DTUHIDMessage.touch(x: x, y: y, phase: phase, target: 0), feature: digitizer)
    }

    static func button(_ usage: UInt64, _ state: DTUHIDMessage.ButtonState) -> DTUHIDStep {
        .send(DTUHIDMessage.button(usagePage: 0x0C, usage: usage, state: state), feature: DTUHIDMessage.buttonService)
    }

    static func key(_ usage: UInt64, _ state: DTUHIDMessage.ButtonState) -> DTUHIDStep {
        .send(DTUHIDMessage.keyboard(usage: usage, state: state), feature: DTUHIDMessage.keyboardService)
    }

    @Test("a tap is start, 60 ms, end at the panel fraction")
    func tap() throws {
        var lowering = DTUHIDLowering(panel: Self.phone)
        #expect(try lowering.steps(for: .tapAt(x: 215, y: 466)) == [Self.touch(0.5, 0.5, .start), .wait(0.06), Self.touch(0.5, 0.5, .end)])
    }

    @Test("a held contact moves as positions until it lifts, across separate events")
    func touchPhases() throws {
        var lowering = DTUHIDLowering(panel: Self.phone)
        #expect(try lowering.steps(for: .touch(direction: .down, x: 0, y: 0)) == [Self.touch(0, 0, .start)])
        #expect(try lowering.steps(for: .touch(direction: .down, x: 430, y: 932)) == [Self.touch(1, 1, .position)])
        #expect(try lowering.steps(for: .touch(direction: .up, x: 430, y: 932)) == [Self.touch(1, 1, .end)])
        #expect(try lowering.steps(for: .touch(direction: .down, x: 0, y: 0)) == [Self.touch(0, 0, .start)])
    }

    @Test("points off the panel are clamped to its edge")
    func clamped() throws {
        var lowering = DTUHIDLowering(panel: Self.phone)
        #expect(try lowering.steps(for: .touch(direction: .down, x: -10, y: 2000)) == [Self.touch(0, 1, .start)])
    }

    @Test("a swipe starts, moves every duration / steps and ends at the last point")
    func swipe() throws {
        var lowering = DTUHIDLowering(panel: Self.phone)
        let steps = try lowering.steps(for: .swipe(0, yStart: 0, xEnd: 0, yEnd: 466, delta: 233, duration: 1))
        #expect(steps == [
            Self.touch(0, 0, .start), .wait(0.5), Self.touch(0, 0.25, .position), .wait(0.5), Self.touch(0, 0.5, .position), Self.touch(0, 0.5, .end),
        ])
    }

    @Test("a swipe with no delta uses idb's 10 point step")
    func swipeDefaultDelta() throws {
        var lowering = DTUHIDLowering(panel: Self.phone)
        let steps = try lowering.steps(for: .swipe(0, yStart: 0, xEnd: 0, yEnd: 100, delta: 0, duration: 0))
        #expect(steps.filter { if case .send = $0 { return true } else { return false } }.count == 12)
        #expect(!steps.contains { if case .wait = $0 { return true } else { return false } })
    }

    @Test("short button presses hold long enough for the device: home briefly, lock past the side button's gate, Siri long", arguments: [
        (HardwareButton.home, UInt64(0x40), 0.08),
        (.lock, 0x30, 0.4),
        (.sideButton, 0x30, 0.4),
        (.siri, 0xCF, 0.85),
    ])
    func shortButtonPress(button: HardwareButton, usage: UInt64, hold: TimeInterval) throws {
        var lowering = DTUHIDLowering(panel: Self.phone)
        #expect(try lowering.steps(for: .shortButtonPress(button)) == [Self.button(usage, .down), .wait(hold), Self.button(usage, .up)])
    }

    @Test("apple-pay is refused as not supported, and Android buttons as unsupported")
    func refusedButtons() {
        var lowering = DTUHIDLowering(panel: Self.phone)
        let applePay = #expect(throws: IOSDeviceError.self) { try lowering.steps(for: .shortButtonPress(.applePay)) }
        #expect(applePay?.reason == .notSupported)
        let back = #expect(throws: IOSDeviceError.self) { try lowering.steps(for: .button(direction: .down, button: .back)) }
        #expect(back?.reason == .unsupportedButton)
    }

    @Test("keys go to the keyboard feature; delays become waits and zero delays vanish")
    func keysAndDelays() throws {
        var lowering = DTUHIDLowering(panel: Self.phone)
        let steps = try lowering.steps(for: .composite([
            .keyboard(direction: .down, keyCode: 227), .shortKeyPress(4), .keyboard(direction: .up, keyCode: 227), .delay(0), .delay(0.05),
        ]))
        #expect(steps == [Self.key(227, .down), Self.key(4, .down), Self.key(4, .up), Self.key(227, .up), .wait(0.05)])
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
        let failure = IOSDeviceError.serviceSocket(info, feature: DTUHIDMessage.digitizerService, name: "iPad", udid: IOSDeviceFixtures.iPad)
        #expect(failure.reason == .deviceLocked)
        #expect(failure.exitCode == .deviceUnavailable)
        #expect(failure.message.contains("Unlock"))
        #expect(failure.message.contains("no input was sent"))
        #expect(failure.hint == "offsider doctor --device \(IOSDeviceFixtures.iPad)")
    }

    @Test("a disk image without the HID service asks for Xcode 27")
    func unsupportedFeature() {
        let info = CoreDeviceErrorInfo(domain: "com.apple.dt.CoreDeviceError", code: 1, description: "Create Service Socket is not supported by this device")
        let failure = IOSDeviceError.serviceSocket(info, feature: DTUHIDMessage.digitizerService, name: "iPad", udid: IOSDeviceFixtures.iPad)
        #expect(failure.reason == .xcodeTooOld)
        #expect(failure.message.contains("Install Xcode 27 for HID input"))
    }

    @Test("a refused barrier on an unlocked device means UI Automation is off; on a locked one, locked")
    func barrier() {
        let unlocked = IOSDeviceError.barrierRefused(CoreDeviceErrorInfo(domain: "dtuhidd", code: 3), name: "iPad", udid: IOSDeviceFixtures.iPad)
        #expect(unlocked.reason == .uiAutomationOff)
        #expect(unlocked.message.contains("Settings > Developer > UI Automation"))
        let locked = IOSDeviceError.barrierRefused(
            CoreDeviceErrorInfo(domain: "x", code: 1, underlying: [CoreDeviceErrorInfo(domain: "RemotePairingError", code: 1016)]), name: "iPad", udid: IOSDeviceFixtures.iPad
        )
        #expect(locked.reason == .deviceLocked)
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

/// Records what a session sends instead of opening CoreDevice sockets.
@MainActor
final class RecordingSink: DTUHIDSink {
    private(set) var sent: [DTUHIDStep] = []
    private(set) var closed = false
    var hasSent: Bool { !sent.isEmpty }

    func send(_ message: DTUHIDValue, feature: String) async throws {
        sent.append(.send(message, feature: feature))
    }

    func close() async {
        closed = true
    }
}

@MainActor
final class RecordingRunnerText: RunnerTextTyping {
    private(set) var calls: [String] = []

    func typeText(_ text: String, on device: DeviceID) async throws { calls.append("type \(text.count)") }
    func replaceText(_ text: String, on device: DeviceID) async throws { calls.append("replace \(text.count)") }
}

@MainActor
final class StubInputSession: InputSession {
    let device: DeviceID
    init(device: DeviceID) { self.device = device }
    func perform(_ event: InputEvent) async throws {}
    func close() async {}
}

@Suite("iOS device input")
@MainActor
struct IOSDeviceInputTests {
    static let phone = DeviceID(rawValue: IOSDeviceFixtures.phone, platform: .ios)

    static func devicectl() throws -> FakeDevicectl {
        try FakeDevicectl.listing("devicectl-list-xcode26.json", extra: [
            "displays": ProcessCaptureResult(status: 0, stdout: try IOSDeviceFixtures.text("devicectl-info-displays.json"), stderr: ""),
        ])
    }

    static func backend(_ devicectl: FakeDevicectl, version: String?, sink: RecordingSink? = nil) -> IOSDeviceBackend {
        let backend = IOSDeviceBackend(host: .fake(devicectl)) { _, _ in }
        backend.input.coreDeviceVersion = { version.flatMap(CoreDeviceVersion.init) }
        if let sink {
            backend.input.makeSink = { _, _, _, _ in sink }
        }
        return backend
    }

    @Test("below CoreDevice 636 with no runner, input refuses with xcode_too_old before reading the panel or opening a socket")
    func belowFloor() async throws {
        let devicectl = try Self.devicectl()
        let sink = RecordingSink()
        let backend = Self.backend(devicectl, version: "518.24", sink: sink)
        backend.input.fallbackInputSession = nil
        let error = await #expect(throws: IOSDeviceError.self) { try await backend.openInputSession(for: Self.phone) }
        #expect(error?.reason == .xcodeTooOld)
        #expect(error?.exitCode == .toolMissing)
        #expect(error?.message.contains("Install Xcode 27 for HID input") == true)
        #expect(!devicectl.calls.contains { $0.contains("displays") })
        #expect(!sink.hasSent)
    }

    @Test("below the floor the fallback session serves input when one is wired in")
    func fallback() async throws {
        let backend = Self.backend(try Self.devicectl(), version: "518.24")
        var asked: [String] = []
        backend.input.fallbackInputSession = { id in
            asked.append(id.rawValue)
            return StubInputSession(device: id)
        }
        let session = try await backend.openInputSession(for: Self.phone)
        #expect(session is StubInputSession)
        #expect(asked == [IOSDeviceFixtures.phone])
    }

    @Test("a tap at the screen's centre in points reaches the digitizer as half the panel, and close drains the sink")
    func tapThroughSession() async throws {
        let devicectl = try Self.devicectl()
        let sink = RecordingSink()
        let backend = Self.backend(devicectl, version: "651.13.4", sink: sink)
        let point = try await backend.deviceCoordinates(for: [(x: 215, y: 466)], tree: nil, on: Self.phone)[0]
        let session = try await backend.openInputSession(for: Self.phone)
        try await session.perform(.tapAt(x: point.x, y: point.y))
        await session.close()

        #expect(sink.sent == [
            .send(DTUHIDMessage.touch(x: 0.5, y: 0.5, phase: .start, target: 0), feature: DTUHIDMessage.digitizerService),
            .send(DTUHIDMessage.touch(x: 0.5, y: 0.5, phase: .end, target: 0), feature: DTUHIDMessage.digitizerService),
        ])
        #expect(sink.closed)
        #expect(devicectl.calls.filter { $0.contains("displays") }.count == 1)
    }

    @Test("an event with an unsupported part sends nothing, not even the parts before it")
    func atomicLowering() async throws {
        let sink = RecordingSink()
        let session = try await Self.backend(try Self.devicectl(), version: "651.13.4", sink: sink).openInputSession(for: Self.phone)
        await #expect(throws: IOSDeviceError.self) {
            try await session.perform(.composite([.tapAt(x: 10, y: 10), .shortButtonPress(.applePay)]))
        }
        #expect(!sink.hasSent)
        try await session.perform(.touch(direction: .down, x: 0, y: 0))
        #expect(sink.sent == [.send(DTUHIDMessage.touch(x: 0, y: 0, phase: .start, target: 0), feature: DTUHIDMessage.digitizerService)])
    }

    @Test("US keyboard text types through HID keys; other text and --replace need the runner")
    func text() async throws {
        let sink = RecordingSink()
        let backend = Self.backend(try Self.devicectl(), version: "651.13.4", sink: sink)
        backend.input.runnerText = nil
        let session = try #require(try await backend.openInputSession(for: Self.phone) as? any TextInputSession)
        try await session.typeText("hI")
        #expect(sink.sent == [
            DTUHIDLoweringTests.key(11, .down), DTUHIDLoweringTests.key(11, .up),
            DTUHIDLoweringTests.key(225, .down), DTUHIDLoweringTests.key(12, .down), DTUHIDLoweringTests.key(12, .up), DTUHIDLoweringTests.key(225, .up),
        ])
        let unicode = await #expect(throws: IOSDeviceError.self) { try await session.typeText("café") }
        #expect(unicode?.reason == .notSupported)
        let replace = await #expect(throws: IOSDeviceError.self) { try await session.replaceText("x") }
        #expect(replace?.reason == .notSupported)
        #expect(sink.sent.count == 6)

        let runner = RecordingRunnerText()
        backend.input.runnerText = runner
        let withRunner = try #require(try await backend.openInputSession(for: Self.phone) as? any TextInputSession)
        try await withRunner.typeText("café")
        try await withRunner.replaceText("ab")
        #expect(runner.calls == ["type 4", "replace 2"])
    }

    @Test("a touch held between commands is refused before any device command", arguments: [
        [DetachedTouchStep.down(x: 1, y: 2)],
        [.up(x: 1, y: 2)],
        [.down(x: 1, y: 2), .up(x: 3, y: 4)],
    ])
    func detachedRefused(steps: [DetachedTouchStep]) async throws {
        let devicectl = try Self.devicectl()
        let sink = RecordingSink()
        let error = await #expect(throws: IOSDeviceError.self) {
            try await Self.backend(devicectl, version: "651.13.4", sink: sink).sendDetachedTouch(steps, to: Self.phone)
        }
        #expect(error?.reason == .notSupported)
        #expect(devicectl.calls.isEmpty)
        #expect(!sink.hasSent)
    }

    @Test("a whole touch with a hold goes down, waits and lifts in one session")
    func detachedWhole() async throws {
        let sink = RecordingSink()
        let backend = Self.backend(try Self.devicectl(), version: "651.13.4", sink: sink)
        try await backend.sendDetachedTouch([.down(x: 215, y: 466), .hold(0.01), .up(x: 215, y: 466)], to: Self.phone)
        #expect(sink.sent == [
            .send(DTUHIDMessage.touch(x: 0.5, y: 0.5, phase: .start, target: 0), feature: DTUHIDMessage.digitizerService),
            .send(DTUHIDMessage.touch(x: 0.5, y: 0.5, phase: .end, target: 0), feature: DTUHIDMessage.digitizerService),
        ])
        #expect(sink.closed)
    }
}
