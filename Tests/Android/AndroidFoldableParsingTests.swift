import Foundation
import OffsiderCore
import Testing
@testable import OffsiderAndroid

@Suite("Android device states and displays")
struct AndroidFoldableParsingTests {
    typealias State = AndroidDeviceState.State

    @Test("a phone lists one device state, so it is not foldable")
    func phoneStates() {
        #expect(AndroidDeviceState.parseStates(FoldableFixtures.pixel9PrintStates) == [State(identifier: 0, name: "DEFAULT")])
        #expect(AndroidDeviceState.parseReading(FoldableFixtures.pixel9State) == .init(committed: State(identifier: 0, name: "DEFAULT"), base: nil, override: nil))
    }

    @Test("a foldable's states map to postures, and states Offsider cannot name are unknown")
    func foldStates() {
        let states = AndroidDeviceState.parseStates(FoldableFixtures.foldPrintStates)
        #expect(states.map(\.identifier) == [0, 1, 2, 3])
        #expect(states.map(\.posture) == [.closed, .halfOpened, .open, .unknown])
        #expect(AndroidDeviceState.parseReading(FoldableFixtures.foldStateOpen) == .init(committed: State(identifier: 2, name: "OPENED"), base: nil, override: nil))
        #expect(AndroidDeviceState.parseReading(FoldableFixtures.foldStateClosed)?.committed.posture == .closed)
    }

    @Test("an override shows the committed, base and override states")
    func overrideReading() throws {
        let reading = try #require(AndroidDeviceState.parseReading(FoldableFixtures.foldStateClosedOverride))
        #expect(reading.committed == State(identifier: 0, name: "CLOSED"))
        #expect(reading.base == State(identifier: 2, name: "OPENED"))
        #expect(reading.override == State(identifier: 0, name: "CLOSED"))
    }

    @Test("output with no device state parses to nothing")
    func junk() {
        #expect(AndroidDeviceState.parseStates("cmd: Can't find service: device_state\n").isEmpty)
        #expect(AndroidDeviceState.parseReading("Error: unknown command\n") == nil)
    }

    @Test("the Pixel 9's one built-in display is main, named by its physical id, and active")
    func phoneDisplays() throws {
        let list = AndroidDisplayList.parse(dumpsys: FoldableFixtures.pixel9Dumpsys)
        let display = try #require(list.displays.first)
        #expect(list.displays.count == 1)
        #expect(display.descriptor == DisplayDescriptor(
            role: .main, platformId: FoldableFixtures.pixel9Id, name: "Built-in Screen",
            pixelWidth: 1080, pixelHeight: 2424, scale: 2.625, nativeOrientation: 0
        ))
        #expect(display.on)
        #expect(list.active?.uniqueId == "local:\(FoldableFixtures.pixel9Id)")
    }

    @Test("a foldable's smaller panel is the cover and the larger the inner; logical display 0, not the disabled one, names the active panel")
    func foldDisplays() {
        let open = AndroidDisplayList.parse(dumpsys: FoldableFixtures.foldDumpsysOpen)
        #expect(open.displays.map(\.descriptor.role) == [.inner, .cover])
        #expect(open.displays.map(\.descriptor.platformId) == [FoldableFixtures.innerId, FoldableFixtures.coverId])
        #expect(open.displays.map(\.on) == [true, false])
        #expect(open.active?.descriptor.role == .inner)
        #expect(open.active.map { ($0.descriptor.pixelWidth, $0.descriptor.pixelHeight) } ?? (0, 0) == (2076, 2152))

        let closed = AndroidDisplayList.parse(dumpsys: FoldableFixtures.foldDumpsysClosed)
        #expect(closed.displays.map(\.on) == [false, true])
        #expect(closed.active?.descriptor.role == .cover)
        #expect(closed.active?.descriptor.pointWidth.rounded() == 443)
    }

    @Test("One UI's CLOSE, HALF_FOLDED and OPEN are postures, its dual-screen states are open, and its tent state is unknown")
    func galaxyFoldStates() {
        let states = AndroidDeviceState.parseStates(GalaxyFoldFixtures.printStates)
        #expect(states.map(\.posture) == [.closed, .unknown, .halfOpened, .open, .open, .open])
        #expect(AndroidDeviceState.parseReading(GalaxyFoldFixtures.state(closed: true))?.committed.posture == .closed)
        #expect(AndroidDeviceState.parseReading(GalaxyFoldFixtures.state(closed: false))?.committed.posture == .open)
    }

    @Test("setting a posture prefers its own state name over another state mapped to it, whatever the order")
    func preferredState() {
        let states = [
            AndroidDeviceState.State(identifier: 4, name: "DUAL"), AndroidDeviceState.State(identifier: 3, name: "OPEN"),
            AndroidDeviceState.State(identifier: 0, name: "CLOSE"),
        ]
        #expect(AndroidDeviceState.preferred(.open, in: states)?.name == "OPEN")
        #expect(AndroidDeviceState.preferred(.closed, in: states)?.identifier == 0)
        #expect(AndroidDeviceState.preferred(.halfOpened, in: states) == nil)
        #expect(AndroidDeviceState.preferred(.open, in: [AndroidDeviceState.State(identifier: 5, name: "REAR_DUAL")])?.identifier == 5)
    }

    @Test("posture output names a state that is not the posture's own, as One UI's or the platform's, in text and JSON")
    func postureStateNamed() {
        #expect(DisplayReport.postureLine(.unknown, screen: nil, platform: .android, state: "TENT") == "Posture: unknown (One UI TENT)")
        #expect(DisplayReport.postureLine(.open, screen: nil, platform: .android, state: "DUAL") == "Posture: open (One UI DUAL)")
        #expect(DisplayReport.postureLine(.open, screen: nil, platform: .android, state: "OPEN") == "Posture: open")
        #expect(DisplayReport.postureLine(.unknown, screen: nil, platform: .android, state: "REAR_DISPLAY_STATE") == "Posture: unknown (state REAR_DISPLAY_STATE)")
        #expect(DisplayReport.postureJSON(.open, previous: nil, screen: nil, platform: .android, state: "DUAL").contains(#""posture":"open","state":"DUAL""#))
    }

    @Test("One UI names no panel for logical display 0, so the only lit panel is the active one")
    func galaxyFoldDisplays() {
        let open = AndroidDisplayList.parse(dumpsys: GalaxyFoldFixtures.dumpsys(closed: false))
        #expect(open.displays.map(\.descriptor.role) == [.inner, .cover])
        #expect(open.displays.map(\.descriptor.platformId) == [GalaxyFoldFixtures.innerId, GalaxyFoldFixtures.coverId])
        #expect(open.activeUniqueId == nil)
        #expect(open.active == nil)
        #expect(open.soleLitPanel?.descriptor.role == .inner)

        let closed = AndroidDisplayList.parse(dumpsys: GalaxyFoldFixtures.dumpsys(closed: true))
        #expect(closed.soleLitPanel?.descriptor.role == .cover)
    }

    @Test("with both panels lit, as in a dual-screen state, no panel is assumed active")
    func bothPanelsLit() {
        let output = GalaxyFoldFixtures.dumpsys(closed: false).replacingOccurrences(of: "state OFF, committedState OFF", with: "state ON, committedState ON")
        #expect(AndroidDisplayList.parse(dumpsys: output).soleLitPanel == nil)
    }

    @Test("a probe fits only the panel its sizes describe, so one taken mid-unfold does not fit the inner panel its viewport names")
    func probeFitsPanel() throws {
        let open = AndroidDisplayList.parse(dumpsys: FoldableFixtures.foldDumpsysOpen)
        let inner = try #require(open.displays.first { $0.descriptor.role == .inner }).descriptor
        let cover = try #require(open.displays.first { $0.descriptor.role == .cover }).descriptor
        let unfolding = try AndroidDisplayGeometry.parse(FoldableFixtures.foldGeometryUnfolding)

        #expect(try AndroidDisplayGeometry.parse(FoldableFixtures.foldGeometryOpen).fits(inner))
        #expect(try AndroidDisplayGeometry.parse(FoldableFixtures.foldGeometryClosed).fits(cover))
        #expect(AndroidDisplayGeometry.viewportUniqueId(in: FoldableFixtures.foldGeometryUnfolding) == "local:\(FoldableFixtures.innerId)")
        #expect(!unfolding.fits(inner))
        #expect(try !AndroidDisplayGeometry.parse(FoldableFixtures.foldGeometryClosed).fits(inner))
        #expect(try AndroidDisplayGeometry.parse(FoldableFixtures.foldGeometryOpen).rotated(to: 1).fits(inner))
    }

    @Test("an external display keeps its role beside a single built-in one")
    func externalDisplay() {
        let output = FoldableFixtures.pixel9Dumpsys.replacingOccurrences(
            of: "Display Devices: size=1",
            with: #"Display Devices: size=2"# + "\n" + #"  DisplayDeviceInfo{"HDMI Screen": uniqueId="local:7", 1920 x 1080, density 160, 160.0 x 160.0 dpi, type EXTERNAL, state ON, installOrientation 0}"#
        )
        let list = AndroidDisplayList.parse(dumpsys: output)
        #expect(list.displays.map(\.descriptor.role) == [.main, .external])
        #expect(list.active?.descriptor.role == .main)
    }

    @Test("display 0's viewport names the physical display it shows")
    func viewportUniqueId() {
        #expect(AndroidDisplayGeometry.viewportUniqueId(in: FoldableFixtures.foldGeometryOpen) == "local:\(FoldableFixtures.innerId)")
        #expect(AndroidDisplayGeometry.viewportUniqueId(in: "Physical size: 1080x2424\n") == nil)
    }

    @Test("a folded frame is cropped to the folded view before it is turned")
    func foldedCrop() throws {
        let width = 2076
        let height = 2152
        var bytes = Data(count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                bytes[offset] = x >= 498 && x < 1578 ? 200 : 10
                bytes[offset + 3] = 255
            }
        }
        var frame = EmulatorFrame(format: .rgba8888, width: width, height: height, emulatorRotation: 0, sequence: 1, bytes: bytes)
        frame.folded = FoldedRect(x: 498, y: 0, width: 1080, height: 2152)

        let pixels = try AndroidScreenCapture.upright(frame, guestRotation: 0)
        #expect(pixels.width == 1080 && pixels.height == 2152)
        #expect(Set(stride(from: 0, to: pixels.bytes.count, by: 4).map { pixels.bytes[$0] }) == [200])
        let png = try AndroidScreenCapture.png(from: frame, guestRotation: 1)
        #expect(try AndroidScreenCaptureTests.labels(ofPNG: png).width == 2152)
    }

    @Test("a folded rectangle outside the frame is clamped to it")
    func foldedCropClamped() {
        let pixels = AndroidScreenCapture.Pixels(width: 3, height: 2, bytes: AndroidScreenCaptureTests.rgba(AndroidScreenCaptureTests.letters))
        let cropped = AndroidScreenCapture.cropped(pixels, to: FoldedRect(x: 1, y: 1, width: 10, height: 10))
        #expect(cropped.width == 2 && cropped.height == 1)
        #expect(stride(from: 0, to: cropped.bytes.count, by: 4).map { cropped.bytes[$0] } == Array("EF".utf8))
    }

    @Test("the folded rectangle comes from Image.format.foldedDisplay, and an empty one means unfolded")
    func foldedFromImage() {
        var image = Android_Emulation_Control_Image()
        image.format.format = .rgba8888
        image.format.width = 2
        image.format.height = 1
        image.image = Data(count: 8)
        #expect(EmulatorControlClient.frame(from: image)?.folded == nil)
        image.format.foldedDisplay.width = 1
        image.format.foldedDisplay.height = 1
        image.format.foldedDisplay.xOffset = 1
        #expect(EmulatorControlClient.frame(from: image)?.folded == FoldedRect(x: 1, y: 0, width: 1, height: 1))
    }

    @Test("postures go to the wire as PostureValue and come back")
    func postureMessages() {
        #expect(EmulatorControlClient.postureMessage(.closed).value == .postureClosed)
        #expect(EmulatorControlClient.postureMessage(.halfOpened).value == .postureHalfOpened)
        #expect(EmulatorControlClient.postureMessage(.opened).value == .postureOpened)
        var message = Android_Emulation_Control_Posture()
        message.value = .postureTent
        #expect(EmulatorControlClient.posture(from: message) == .tent)
    }

    @Test("a notification's other members are skipped as unknown fields, leaving its posture")
    func notificationUnknownFields() throws {
        // Field 5 (booted, a BootCompletedNotification with time 7), then field 4 (posture, value 1).
        let wire = Data([0x2A, 0x02, 0x08, 0x07, 0x22, 0x02, 0x18, 0x01])
        let notification = try Android_Emulation_Control_Notification(serializedBytes: wire)
        #expect(notification.posture.value == .postureClosed)
    }
}
