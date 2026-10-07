import Foundation
import OffsiderCore
import Testing
@testable import Offsider

@Suite("Displays and posture commands")
@MainActor
struct DisplayCommandTests {
    static let device = DeviceID(rawValue: "SIM", platform: .ios)
    nonisolated static let coverScreen = UIScreenInfo(
        width: 466, height: 678, scale: 3, rotation: .portrait, rotationDegrees: 0,
        display: ScreenDisplay(id: "cover", platformId: "1"), posture: .closed
    )
    nonisolated static let innerScreen = UIScreenInfo(
        width: 951, height: 669, scale: 3, rotation: .landscape, rotationDegrees: 0,
        display: ScreenDisplay(id: "inner", platformId: "3"), posture: .open
    )

    static func folded(screen: UIScreenInfo = coverScreen, screenshots: [Data] = []) -> FakeDeviceBackend {
        let backend = FakeDeviceBackend(trees: [], screenshots: screenshots, screen: screen)
        backend.displayList = DisplayReportTests.folded
        return backend
    }

    private func posture(
        _ target: Posture?, angle: Int? = nil, json: Bool = false, timeout: TimeInterval = 10, on backend: FakeDeviceBackend, clock: ScriptedClock? = nil
    ) async throws -> String {
        let poll = (clock ?? ScriptedClock()).poll
        return try await PostureCommand.report(
            target, angle: angle, json: json, timeout: timeout, on: Self.device, backend: backend, deviceName: "SIM", sleep: poll.sleep, now: poll.now
        )
    }

    @Test("displays prints the table, or the JSON object")
    func displays() async throws {
        let backend = Self.folded()
        #expect(try await Displays.report(json: false, on: Self.device, backend: backend, deviceName: "SIM") == DisplayReport.table(DisplayReportTests.folded, platform: .ios))
        #expect(try await Displays.report(json: true, on: Self.device, backend: backend, deviceName: "SIM").hasPrefix(#"{"displays":[{"id":"cover""#))
    }

    @Test("a phone lists one main display and is not foldable")
    func phoneDisplays() async throws {
        let text = try await Displays.report(json: false, on: Self.device, backend: FakeDeviceBackend(trees: []), deviceName: "SIM")
        #expect(text.hasSuffix("main  1            402x874 pt  3      0         yes\nPosture: not foldable"))
    }

    @Test("posture reads the posture with the active display and its size")
    func read() async throws {
        let backend = Self.folded()
        #expect(try await posture(nil, on: backend) == "Posture: closed (cover, 466 x 678 pt)")
        #expect(try await posture(nil, json: true, on: backend) == #"{"posture":"closed","state":null,"previous":null,"display":"cover","screen":{"width":466,"height":678}}"#)
        #expect(backend.requestedPostures.isEmpty)
    }

    @Test("a device with one display is not foldable")
    func notFoldable() async {
        await #expect {
            try await posture(nil, on: FakeDeviceBackend(trees: []))
        } throws: { "\($0)" == "SIM is not a foldable device; it has one display." }
    }

    @Test("setting the posture the device already has sends nothing")
    func alreadyThere() async throws {
        let backend = Self.folded()
        #expect(try await posture(.closed, json: true, on: backend) == #"{"posture":"closed","state":null,"previous":"closed","display":"cover","screen":{"width":466,"height":678}}"#)
        #expect(backend.requestedPostures.isEmpty)
    }

    @Test("a simulator without the hinge service refuses to set the posture and says how to fold it")
    func iosRefuses() async {
        let backend = Self.folded()
        backend.postureRequestError = CLIError(errorDescription: IOSBackend.postureUnavailable(device: "SIM"))
        await #expect {
            try await posture(.open, on: backend)
        } throws: {
            "\($0)" == "Setting the posture is not available on this iOS simulator: its runtime has no hinge service Offsider can reach. Fold or unfold it in Device Hub, then check with `offsider posture --device SIM`."
        }
        #expect(backend.requestedPostures == [.open])
    }

    @Test("a posture that lands after a few reads is reported with the one before")
    func setReached() async throws {
        let backend = Self.folded(screen: Self.innerScreen)
        backend.postures = [.closed, .closed, .halfOpened, .open]
        #expect(try await posture(.open, json: true, on: backend) == #"{"posture":"open","state":null,"previous":"closed","display":"inner","screen":{"width":951,"height":669}}"#)
        #expect(backend.requestedPostures == [.open])
    }

    @Test("a posture that never lands times out after one resend")
    func setTimesOut() async {
        let backend = Self.folded()
        let clock = ScriptedClock()
        await #expect {
            try await posture(.open, timeout: 1, on: backend, clock: clock)
        } throws: { "\($0)" == "The simulator did not report open within 1 s. Check with `offsider posture --device SIM`." }
        #expect(backend.requestedPostures == [.open, .open])
        #expect(clock.now >= 1)
    }

    @Test("--angle moves the hinge, waits for the reading, then reports the posture once it settles")
    func angle() async throws {
        let backend = Self.folded(screen: Self.innerScreen)
        backend.hingeAngles = [180, 150, 121, 120]
        backend.postures = [.open, .halfOpened, .halfOpened]
        #expect(try await posture(nil, angle: 120, json: true, on: backend) == #"{"posture":"half-opened","state":null,"previous":"open","display":"inner","screen":{"width":951,"height":669}}"#)
        #expect(backend.requestedAngles == [120])
        #expect(backend.requestedPostures.isEmpty)
    }

    @Test("--angle at the hinge's current reading sends nothing and reports the posture unchanged")
    func angleAlreadyThere() async throws {
        let backend = Self.folded(screen: Self.innerScreen)
        backend.hingeAngles = [180]
        backend.postures = [.open]
        #expect(try await posture(nil, angle: 180, json: true, on: backend) == #"{"posture":"open","state":null,"previous":"open","display":"inner","screen":{"width":951,"height":669}}"#)
        #expect(backend.requestedAngles.isEmpty)
        #expect(backend.requestedPostures.isEmpty)
    }

    @Test("--angle at the hinge's reading still moves it when the other panel is showing")
    func angleThereButPanelDisagrees() async throws {
        let backend = Self.folded(screen: Self.innerScreen)
        backend.hingeAngles = [180]
        backend.postures = [.closed, .open]
        #expect(try await posture(nil, angle: 180, json: true, on: backend) == #"{"posture":"open","state":null,"previous":"closed","display":"inner","screen":{"width":951,"height":669}}"#)
        #expect(backend.requestedAngles == [180])
    }

    @Test("--angle that the hinge never reads times out naming the angle")
    func angleTimesOut() async {
        let backend = Self.folded()
        backend.hingeAngles = [0]
        await #expect {
            try await posture(nil, angle: 90, timeout: 1, on: backend)
        } throws: { "\($0)" == "The hinge did not reach 90 degrees within 1 s. Check with `offsider posture --device SIM`." }
        #expect(backend.requestedAngles == [90, 90])
    }

    @Test("posture --angle validates its range and refuses a posture name too")
    func angleValidation() throws {
        #expect(throws: (any Error).self) { try PostureCommand.parse(["--angle", "181", "--device", "SIM"]) }
        #expect(throws: (any Error).self) { try PostureCommand.parse(["open", "--angle", "90", "--device", "SIM"]) }
        #expect(try PostureCommand.parse(["--angle", "0", "--device", "SIM"]).angle == 0)
    }

    @Test("describe-ui --display accepts the active display and refuses one that is not active")
    func describeActiveOnly() async throws {
        let route = DeviceRouter.Route(backend: Self.folded(), device: Self.device)
        try await DescribeUI.requireActive(try DisplayOption.parse(["--display", "cover"]), on: route, deviceName: "SIM")
        try await DescribeUI.requireActive(try DisplayOption.parse([]), on: route, deviceName: "SIM")
        await #expect {
            try await DescribeUI.requireActive(try DisplayOption.parse(["--display", "3"]), on: route, deviceName: "SIM")
        } throws: {
            "\($0)" == "describe-ui reads the active display only, and inner is not active (posture closed). Unfold the simulator with `offsider posture open --device SIM`, then retry."
        }
        await #expect {
            try await DescribeUI.requireActive(try DisplayOption.parse(["--display", "external"]), on: route, deviceName: "SIM")
        } throws: { "\($0)" == "Unknown display 'external' on SIM. Use one of: cover (1), inner (3)." }
    }

    @Test("screenshot --display captures a display that is not active at its own size")
    func captureInactive() async throws {
        let png = try ScreenImage.encode(TestImages.make(width: 2007, height: 2853), as: .png)
        let backend = Self.folded(screenshots: [png])
        let list = DisplayReportTests.folded
        let capture = try await ScreenCapture.capture(backend, device: Self.device, display: list.displays[1], posture: list.posture)
        let report = try ScreenCapture.render(capture, request: ScreenshotRequest(scale: .points)).report(path: nil, format: nil, capture: capture)

        #expect(backend.capturedDisplays == ["3"])
        #expect(report.jsonLine() == #"{"path":null,"width":669,"height":951,"pixelsPerPoint":1,"region":null,"orientation":"portrait","rotation":null,"display":{"id":"inner","platformId":"3"},"posture":"closed","upright":true,"format":null}"#)
    }

    @Test("screenshot --display on the active display uses the device's screen")
    func captureActive() async throws {
        let png = try ScreenImage.encode(TestImages.make(width: 1398, height: 2034), as: .png)
        let backend = Self.folded(screenshots: [png])
        let capture = try await ScreenCapture.capture(backend, device: Self.device, display: DisplayReportTests.folded.displays[0], posture: .closed)

        #expect(backend.capturedDisplays == ["1"])
        #expect(capture.screen == Self.coverScreen)
        #expect(capture.pixelsPerPoint == 3)
    }
}
