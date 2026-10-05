import FBSimulatorControl
import Foundation
import IOKit
import OffsiderCore
import Testing
import XPC
@testable import Offsider

/// Measured on the unfolded iPhone Duo held in portrait: the inner panel is 2007 x 2853 px, its UI landscape-right on it at 951 x 669 pt,
/// and a digitizer fraction (fx, fy) landed at UI point ((1 - fy) x 951, fx x 669).
@Suite("Foldable panel geometry")
struct PanelGeometryTests {
    static let inner = PanelGeometry(display: DuoFixtures.inner, orientation: .landscape)
    static let mainScreen = (width: 466.0, height: 678.0)

    @Test("the unfolded inner display is 951 x 669 pt landscape, its UI 270 degrees anticlockwise on the panel, with the device in portrait at 0")
    func innerSize() {
        #expect(Self.inner.width == 951 && Self.inner.height == 669)
        #expect(UIScreenInfo(width: Self.inner.width, height: Self.inner.height).shape == .landscape)
        #expect(Self.inner.panelRotationDegrees == 270)
        #expect(Self.inner.deviceOrientation == .portrait)
        #expect(Self.inner.deviceOrientation?.rotationDegrees == 0)
    }

    @Test("the folded cover display is 466 x 678 pt portrait at 0 degrees")
    func coverSize() {
        let cover = PanelGeometry(display: DuoFixtures.cover, orientation: .portrait)
        #expect(cover.width == 466 && cover.height == 678)
        #expect(cover.panelRotationDegrees == 0)
        #expect(cover.deviceOrientation == .portrait)
    }

    @Test("UI points map to the digitizer fractions that landed there", arguments: [
        ((475.5, 200.7), (0.3, 0.5)),
        ((665.7, 133.8), (0.2, 0.3)),
        ((237.75, 167.25), (0.25, 0.75)),
        ((570.6, 267.6), (0.4, 0.4)),
        ((760.8, 133.8), (0.2, 0.2)),
    ] as [((Double, Double), (Double, Double))])
    func fractions(point: (Double, Double), fraction: (Double, Double)) {
        let mapped = Self.inner.panelFraction(x: point.0, y: point.1)
        #expect(abs(mapped.x - fraction.0) < 0.001 && abs(mapped.y - fraction.1) < 0.001, "\(point) gave \(mapped)")
    }

    @Test("a UI point leaves in main-screen points that idb would turn into the same fractions")
    func mainScreenPoints() {
        let point = Self.inner.mainScreenPoint(x: 300, y: 500, mainWidth: Self.mainScreen.width, mainHeight: Self.mainScreen.height)
        let fraction = Self.inner.panelFraction(x: 300, y: 500)
        #expect(abs(point.x / Self.mainScreen.width - fraction.x) < 1e-9)
        #expect(abs(point.y / Self.mainScreen.height - fraction.y) < 1e-9)
        #expect(abs(fraction.x - 500.0 / 669) < 1e-9 && abs(fraction.y - (1 - 300.0 / 951)) < 1e-9)
    }

    @Test("the device turns with the UI, less the panel's mounting", arguments: [
        (OrientationCoordinateMath.Orientation.landscape, DeviceOrientation.portrait),
        (.portrait, .landscapeLeft),
        (.landscapeFlipped, .portraitUpsideDown),
        (.portraitUpsideDown, .landscapeRight),
    ])
    func deviceOrientation(panel: OrientationCoordinateMath.Orientation, device: DeviceOrientation) {
        let geometry = PanelGeometry(display: DuoFixtures.inner, orientation: panel)
        #expect(geometry.deviceOrientation == device)
        #expect(Set([geometry.width, geometry.height]) == [669, 951])
    }

    @Test("an application frame that is the screen turned takes the screen's size; others are kept")
    func sidewaysApplicationFrame() {
        let roots = [FakeUI.node(.application, frame: FakeUI.frame(0, 0, 669, 951), children: [FakeUI.node(.group, frame: FakeUI.frame(0, 0, 951, 669))])]
        let corrected = UITree.correctingSidewaysApplicationFrame(in: roots, screenWidth: 951, screenHeight: 669)
        #expect(corrected[0].frame == FakeUI.frame(0, 0, 951, 669))
        #expect(corrected[0].children == roots[0].children)
        #expect(UITree.correctingSidewaysApplicationFrame(in: roots, screenWidth: 669, screenHeight: 951) == roots)
        #expect(UITree.correctingSidewaysApplicationFrame(in: roots, screenWidth: 466, screenHeight: 678) == roots)
    }
}

@Suite("Hinge control")
struct HingeControlTests {
    @Test("the payload is IOKit XML that IOCFUnserialize reads back as the slider's reading, in whole degrees", arguments: [0, 120, 180])
    func payload(degrees: Int) throws {
        let data = HingeControl.payload(degrees: degrees)
        #expect(data.count < 300, "locationd refused a 403-byte XML plist as too large")
        var error: Unmanaged<CFString>?
        let parsed = data.withUnsafeBytes { bytes in
            IOCFUnserialize(bytes.baseAddress!.assumingMemoryBound(to: CChar.self), kCFAllocatorDefault, 0, &error)
        }
        let dictionary = try #require(parsed as? [String: Any], "\(String(describing: error?.takeRetainedValue()))")
        #expect(dictionary["provider"] as? String == "com.apple.Virtualization.VirtualMachines")
        #expect(dictionary["source"] as? String == "hinge-slider-control")
        #expect(dictionary["type"] as? String == "range")
        #expect((dictionary["value"] as? NSNumber)?.intValue == degrees)
    }

    @Test("the payload matches IOCFSerialize's own output for the same reading, byte for byte in length")
    func matchesIOCFSerialize() throws {
        let reference: NSDictionary = [
            "provider": "com.apple.Virtualization.VirtualMachines", "source": "hinge-slider-control", "type": "range", "value": NSNumber(value: 170),
        ]
        let serialized = try #require(IOCFSerialize(reference, 0)) as Data
        #expect(HingeControl.payload(degrees: 170).count == serialized.count)
    }

    @Test("the event is a vendor-defined HID event on page 0xff61, usage 0x5b, for the vendor-defined service")
    func event() {
        guard case let .dictionary(message) = HingeControl.event(degrees: 90), case let .dictionary(payload)? = message["payload"] else {
            Issue.record("not a dictionary")
            return
        }
        #expect(message["messageType"] == .string("IndigoVendorDefinedEvent"))
        #expect(message["featureIdentifier"] == .string("com.apple.coredevice.feature.remote.hid.vendordefined"))
        #expect(message["isBarrier"] == .bool(false))
        #expect(payload["usagePage"] == .uint(0xff61) && payload["usage"] == .uint(0x5b) && payload["version"] == .uint(0))
        #expect(payload["data"] == .data(HingeControl.payload(degrees: 90)))
    }

    @Test("postures set the angles Device Hub's slider uses")
    func angles() {
        #expect(HingeControl.angle(for: .closed) == 0)
        #expect(HingeControl.angle(for: .halfOpened) == 120)
        #expect(HingeControl.angle(for: .open) == 180)
        #expect(HingeControl.angle(for: .unknown) == nil)
    }

    @Test("a sweep moves in whole degrees at 60 Hz for half a second and ends on the target")
    func sweep() {
        let closing = HingeControl.sweep(from: 180, to: 0)
        #expect(closing.first == 180 && closing.last == 0)
        #expect(closing.count == 32)
        #expect(zip(closing, closing.dropFirst()).allSatisfy { $0 > $1 })
        #expect(HingeControl.sweep(from: 178, to: 180) == [178, 179, 180])
        #expect(HingeControl.sweep(from: 120, to: 120) == [120])
    }

    @Test("the cover display matches a closed hinge and the inner display any other angle; unknown never disagrees", arguments: [
        (Posture.closed, 0, true), (.open, 0, false), (.closed, 180, false), (.open, 180, true),
        (.halfOpened, 120, true), (.closed, 120, false), (.open, 120, true), (.unknown, 0, true),
    ] as [(Posture, Int, Bool)])
    func panelMatches(posture: Posture, angle: Int, matches: Bool) {
        #expect(HingeControl.panelMatches(posture, angle: angle) == matches)
    }

    @Test("a sweep starts at the current posture's angle, else from the far end", arguments: [
        (Posture?.some(.open), 0, 180),
        (.closed, 180, 0),
        (.halfOpened, 0, 120),
        (.open, 180, 0),
        (.unknown, 180, 0),
        (nil, 0, 180),
    ] as [(Posture?, Int, Int)])
    func start(current: Posture?, target: Int, start: Int) {
        #expect(HingeControl.start(from: current, to: target) == start)
    }
}

@Suite("Fresh readings")
@MainActor
struct FreshReadingsTests {
    final class Clock {
        var now: TimeInterval = 0
    }

    @Test("a reading is served again within the window, and read afresh once it is older or forgotten")
    func window() async {
        let clock = Clock()
        let readings = FreshReadings<Int?>(window: 1, now: { clock.now })
        var reads = 0
        let read: () async -> Int? = {
            reads += 1
            return reads
        }
        #expect(await readings.value(for: "A", read: read) == 1)
        clock.now = 0.9
        #expect(await readings.value(for: "A", read: read) == 1)
        #expect(await readings.value(for: "B", read: read) == 2)
        clock.now = 1.0
        #expect(await readings.value(for: "A", read: read) == 3)
        readings.forget("A")
        #expect(await readings.value(for: "A", read: read) == 4)
        #expect(reads == 4)
    }

    @Test("a missing reading is held for the window too, so a device that cannot say is not asked on every poll")
    func missing() async {
        let clock = Clock()
        let readings = FreshReadings<Int?>(window: 1, now: { clock.now })
        var reads = 0
        let read: () async -> Int? = {
            reads += 1
            return nil
        }
        #expect(await readings.value(for: "A", read: read) == nil)
        #expect(await readings.value(for: "A", read: read) == nil)
        #expect(reads == 1)
    }
}

@Suite("DTUHID messages")
struct DTUHIDMessageTests {
    @Test("a touch on another display carries its screen ID as the target, at panel fractions")
    func touch() {
        #expect(DTUHIDMessage.touch(x: 0.25, y: 0.75, phase: .start, target: 3) == .dictionary([
            "messageType": .string("IndigoDigitizerEvent"),
            "isBarrier": .bool(false),
            "featureIdentifier": .string("com.apple.coredevice.feature.remote.hid.digitizer"),
            "payload": .dictionary([
                "pointOne": .dictionary(["x": .double(0.25), "y": .double(0.75)]),
                "eventType": .uint(0),
                "edge": .uint(0),
                "target": .uint(3),
            ]),
        ]))
    }

    @Test("the barrier is keyboard usage 0 up, flagged as a barrier, on the service it probes")
    func barrier() {
        guard case let .dictionary(message) = DTUHIDMessage.barrier(service: DTUHIDMessage.vendorDefinedService) else { return }
        #expect(message["isBarrier"] == .bool(true))
        #expect(message["featureIdentifier"] == .string(DTUHIDMessage.vendorDefinedService))
        #expect(message["payload"] == .dictionary(["usageCode": .uint(0), "state": .uint(2)]))
    }

    @Test("one contact starts, moves while down, and ends")
    func contact() {
        var contact = DTUHIDContact()
        #expect(contact.phase(touchingDown: true) == .start)
        #expect(contact.phase(touchingDown: true) == .position)
        #expect(contact.phase(touchingDown: false) == .end)
        #expect(contact.phase(touchingDown: true) == .start)
    }

    @Test("values become XPC objects of the wire types dtuhidd decodes")
    func xpc() {
        let object = DTUHIDValue.dictionary(["n": .uint(7), "d": .double(0.5), "b": .bool(true), "s": .string("x"), "data": .data(Data([1, 2]))]).xpcObject
        #expect(xpc_dictionary_get_uint64(object, "n") == 7)
        #expect(xpc_dictionary_get_double(object, "d") == 0.5)
        #expect(xpc_dictionary_get_bool(object, "b"))
        #expect(xpc_dictionary_get_string(object, "s").map { String(cString: $0) } == "x")
        var length = 0
        #expect(xpc_dictionary_get_data(object, "data", &length) != nil && length == 2)
    }

    @Test("touches and delays go to the display's digitizer; keys and buttons still go through idb")
    func routing() {
        #expect(IOSDisplayInputSession.isTouchOnly(.tapAt(x: 1, y: 2)))
        #expect(IOSDisplayInputSession.isTouchOnly(.swipe(0, yStart: 0, xEnd: 10, yEnd: 10, delta: 5, duration: 0.2)))
        #expect(!IOSDisplayInputSession.isTouchOnly(.shortKeyPress(4)))
        #expect(!IOSDisplayInputSession.isTouchOnly(.composite([.touch(direction: .down, x: 1, y: 1), .keyboard(direction: .down, keyCode: 4)])))
    }
}
