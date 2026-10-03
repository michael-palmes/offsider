import Foundation
import OffsiderCore
import Testing

/// The iPhone Duo device type's `capabilities.displays`, trimmed to the keys Offsider reads.
enum DuoFixtures {
    static let capabilities: [String: Any] = [
        "capabilities": [
            "displays": [
                ["deviceName": "primary", "displayName": "LCD", "displayType": "integrated", "screenID": 1, "width": 1398, "height": 2034, "scale": 3, "nativeOrientation": 0],
                ["deviceName": "primary-1", "displayName": "LCD-1", "displayType": "integrated", "screenID": 3, "width": 2007, "height": 2853, "scale": 3, "nativeOrientation": 270],
                ["deviceName": "external-0", "displayName": "TVOut", "displayType": "tvOut", "screenID": 2, "width": 720, "height": 480, "scale": 1],
                ["deviceName": "wireless0", "displayName": "Wireless", "displayType": "carPlay", "screenID": 4, "width": 720, "height": 480, "scale": 1],
                ["deviceName": "resizable", "displayName": "Resizable", "displayType": "scene", "screenID": 5, "width": 7680, "height": 4320, "scale": 3],
            ] as [[String: Any]],
        ] as [String: Any],
    ]

    static var profile: [DisplayDescriptor] { SimulatorDisplayProfile.displays(capabilities: capabilities)! }
    static var cover: DisplayDescriptor { profile[0] }
    static var inner: DisplayDescriptor { profile[1] }

    /// `devicectl device info displays --json-output` from the folded iPhone Duo simulator, trimmed.
    static func devicectl(coverActive: Bool = true, innerRotation: String = "rot90") -> Data {
        Data("""
        {
          "info": {"commandType": "devicectl.device.info.displays", "jsonVersion": 5, "outcome": "success"},
          "result": {
            "backlightState": "activeOn",
            "displays": [
              {"active": \(coverActive), "currentOrientation": "rot0", "displayId": 1, "name": "LCD", "nativeOrientation": "rot0",
               "nativeSize": [1398, 2034], "pointScale": 3, "primary": true, "type": {"integrated": {}}},
              {"active": \(!coverActive), "currentOrientation": "\(innerRotation)", "displayId": 3, "name": "LCD-1", "nativeOrientation": "rot0",
               "nativeSize": [2007, 2853], "pointScale": 3, "primary": false, "type": {"integrated": {}}},
              {"active": false, "currentOrientation": "rot0", "displayId": 5, "name": "Resizable", "nativeOrientation": "rot0",
               "nativeSize": [7680, 4320], "pointScale": 3, "primary": false, "type": {"virtual": {}}}
            ],
            "orientation": {"currentDeviceOrientation": "portrait", "currentDeviceOrientationLocked": false}
          }
        }
        """.utf8)
    }
}

@Suite("Simulator display profile")
struct SimulatorDisplayProfileTests {
    @Test("the Duo profile gives a cover on screen 1 and a sideways inner display on screen 3, and drops the other display types")
    func duo() {
        let profile = DuoFixtures.profile
        #expect(profile == [
            DisplayDescriptor(role: .cover, platformId: "1", name: "LCD", pixelWidth: 1398, pixelHeight: 2034, scale: 3, nativeOrientation: 0),
            DisplayDescriptor(role: .inner, platformId: "3", name: "LCD-1", pixelWidth: 2007, pixelHeight: 2853, scale: 3, nativeOrientation: 270),
        ])
        #expect(profile[0].pointWidth == 466)
        #expect(profile[0].pointHeight == 678)
        #expect(profile[1].pointWidth == 669)
        #expect(profile[1].pointHeight == 951)
    }

    @Test("the plist file's data parses the same as the dictionary")
    func plistData() throws {
        let data = try PropertyListSerialization.data(fromPropertyList: DuoFixtures.capabilities, format: .xml, options: 0)
        #expect(SimulatorDisplayProfile.displays(plist: data) == DuoFixtures.profile)
    }

    @Test("one integrated display is main")
    func single() {
        let capabilities: [String: Any] = ["displays": [
            ["displayName": "LCD", "displayType": "integrated", "screenID": 1, "width": 1206, "height": 2622, "scale": 3, "nativeOrientation": 0],
            ["displayName": "TVOut", "displayType": "tvOut", "screenID": 2, "width": 720, "height": 480, "scale": 1],
        ] as [[String: Any]]]
        let profile = SimulatorDisplayProfile.displays(capabilities: capabilities)
        #expect(profile?.map(\.role) == [.main])
        #expect(profile?.first?.pointWidth == 402)
    }

    @Test("a profile with no integrated display, or no displays, gives nothing")
    func empty() {
        #expect(SimulatorDisplayProfile.displays(capabilities: ["displays": [["displayType": "tvOut", "screenID": 2, "width": 720, "height": 480]]]) == nil)
        #expect(SimulatorDisplayProfile.displays(capabilities: [:]) == nil)
        #expect(SimulatorDisplayProfile.displays(plist: Data("not a plist".utf8)) == nil)
    }
}

@Suite("devicectl displays")
struct DevicectlDisplaysTests {
    @Test("the folded capture marks the cover active upright and the inner display turned")
    func folded() throws {
        let parsed = try DevicectlDisplays.parse(json: DuoFixtures.devicectl())
        #expect(parsed.displays.map(\.displayId) == [1, 3, 5])
        #expect(parsed.displays.map(\.active) == [true, false, false])
        #expect(parsed.displays.map(\.currentRotation) == [0, 90, 0])
        #expect(parsed.displays.map(\.integrated) == [true, true, false])
    }

    @Test("rotation names are quarter turns only", arguments: [("rot0", 0), ("rot90", 90), ("rot180", 180), ("rot270", 270)])
    func degrees(text: String, degrees: Int) {
        #expect(DevicectlDisplays.degrees(text) == degrees)
    }

    @Test("unknown rotation names read as unknown", arguments: ["rot45", "portrait", "", "rot"])
    func unknownDegrees(text: String) {
        #expect(DevicectlDisplays.degrees(text) == nil)
    }

    @Test("output without displays is an error")
    func malformed() {
        #expect(throws: DeviceSettingsError.self) { try DevicectlDisplays.parse(json: Data(#"{"result":{}}"#.utf8)) }
    }

    @Test("the hinge angle comes from the first Angle reading")
    func hinge() {
        let output = """
        Hinge angle monitoring started. 1 seconds remaining:
        ? +0.000s : Angle:  92.5  Mech:  92.5  Velocity:+0.0/s  AngleValid:Y  VelocityValid:N  Range:0-180
        ? +0.100s : Angle:  180.0  Mech:  180.0
        """
        #expect(DevicectlDisplays.hingeAngle(in: output) == 92.5)
        #expect(DevicectlDisplays.hingeAngle(in: "Hinge angle monitoring started.") == nil)
    }

    @Test("hinge angles read as postures", arguments: [(0.0, Posture.closed), (90, .halfOpened), (170, .open), (180, .open)])
    func hingePosture(angle: Double, posture: Posture) {
        #expect(Posture(hingeAngle: angle) == posture)
    }
}

@Suite("Active display")
struct ActiveDisplayTests {
    @Test("devicectl's active cover means closed, at its rotation")
    func folded() throws {
        let active = try #require(ActiveDisplay.resolve(
            profile: DuoFixtures.profile, devicectl: try DevicectlDisplays.parse(json: DuoFixtures.devicectl()), applicationFrame: nil
        ))
        #expect(active.descriptor == DuoFixtures.cover)
        #expect(active.posture == .closed)
        #expect(active.rotationDegrees == 0)
        #expect(active.source == .devicectl)
        #expect(active.rotations == ["1": 0, "3": 90, "5": 0])
    }

    @Test("devicectl's active inner display means open, at its rotation")
    func unfolded() throws {
        let active = try #require(ActiveDisplay.resolve(
            profile: DuoFixtures.profile,
            devicectl: try DevicectlDisplays.parse(json: DuoFixtures.devicectl(coverActive: false, innerRotation: "rot90")),
            applicationFrame: nil
        ))
        #expect(active.descriptor == DuoFixtures.inner)
        #expect(active.posture == .open)
        #expect(active.rotationDegrees == 90)
    }

    @Test("without devicectl, the application frame picks the display of its size in either orientation", arguments: [
        ((width: 466.0, height: 678.0), DisplayRole.cover),
        ((width: 951.0, height: 669.0), .inner),
    ] as [((width: Double, height: Double), DisplayRole)])
    func applicationFrame(frame: (width: Double, height: Double), role: DisplayRole) throws {
        let active = try #require(ActiveDisplay.resolve(profile: DuoFixtures.profile, devicectl: nil, applicationFrame: frame))
        #expect(active.descriptor.role == role)
        #expect(active.source == .applicationFrame)
        #expect(active.rotationDegrees == nil)
    }

    @Test("with nothing to go on, screen 1 with an unknown posture")
    func fallback() throws {
        let active = try #require(ActiveDisplay.resolve(profile: DuoFixtures.profile, devicectl: nil, applicationFrame: (width: 300, height: 300)))
        #expect(active.descriptor.platformId == "1")
        #expect(active.posture == .unknown)
        #expect(active.source == .fallback)
    }

    @Test("one display has no posture and needs no devicectl")
    func single() throws {
        let main = DisplayDescriptor(role: .main, platformId: "1", name: "LCD", pixelWidth: 1206, pixelHeight: 2622, scale: 3, nativeOrientation: 0)
        let active = try #require(ActiveDisplay.resolve(profile: [main], devicectl: nil, applicationFrame: nil))
        #expect(active.posture == nil)
        #expect(active.source == .single)
        #expect(ActiveDisplay.resolve(profile: [], devicectl: nil, applicationFrame: nil) == nil)
    }
}

@Suite("Display selection and reports")
struct DisplayReportTests {
    static let folded = DisplayList(
        displays: [
            DisplayInfo(descriptor: DuoFixtures.cover, pointWidth: 466, pointHeight: 678, rotationDegrees: 0, active: true),
            DisplayInfo(descriptor: DuoFixtures.inner, pointWidth: 669, pointHeight: 951, rotationDegrees: 90, active: false),
        ],
        posture: .closed
    )

    @Test("a display is chosen by role or platform id, case-insensitively")
    func resolve() throws {
        #expect(try Self.folded.resolve("Inner", device: "D").descriptor.platformId == "3")
        #expect(try Self.folded.resolve("1", device: "D").descriptor.role == .cover)
    }

    @Test("an unknown display lists the valid ones")
    func unknown() {
        #expect(throws: DeviceSettingsError("Unknown display 'main' on D. Use one of: cover (1), inner (3).")) {
            try Self.folded.resolve("main", device: "D")
        }
    }

    @Test("the table aligns its columns and ends with the posture")
    func table() {
        #expect(DisplayReport.table(Self.folded, platform: .ios) == """
        ID     PLATFORM ID  SIZE        SCALE  ROTATION  ACTIVE
        cover  1            466x678 pt  3      0         yes
        inner  3            669x951 pt  3      90        no
        Posture: closed
        """)
    }

    @Test("one display reads as not foldable, and an unknown rotation as a dash")
    func singleTable() {
        let main = DisplayDescriptor(role: .main, platformId: "0", name: "Built-in", pixelWidth: 1080, pixelHeight: 2424, scale: 2.625, nativeOrientation: 0)
        let list = DisplayList(displays: [DisplayInfo(descriptor: main, pointWidth: 411.43, pointHeight: 923.43, rotationDegrees: nil, active: true)], posture: nil)
        #expect(DisplayReport.table(list, platform: .android) == """
        ID    PLATFORM ID  SIZE              SCALE  ROTATION  ACTIVE
        main  0            411.43x923.43 dp  2.625  -         yes
        Posture: not foldable
        """)
    }

    @Test("the JSON keeps its key order")
    func json() {
        #expect(DisplayReport.json(Self.folded) == #"{"displays":[{"id":"cover","platformId":"1","name":"LCD","width":466,"height":678,"scale":3,"rotation":0,"active":true},{"id":"inner","platformId":"3","name":"LCD-1","width":669,"height":951,"scale":3,"rotation":90,"active":false}],"posture":"closed"}"#)
    }

    @Test("describe-ui on a display that is not active says how to make it active", arguments: [
        (DevicePlatform.ios, "describe-ui reads the active display only, and inner is not active (posture closed). Unfold the simulator in Device Hub, then retry."),
        (.android, "describe-ui reads the active display only, and inner is not active (posture closed). Unfold the emulator with `offsider posture open --device D`, then retry."),
    ])
    func inactive(platform: DevicePlatform, message: String) {
        #expect(DisplayReport.inactiveDisplay(Self.folded.displays[1], posture: .closed, platform: platform, device: "D") == message)
    }
}
