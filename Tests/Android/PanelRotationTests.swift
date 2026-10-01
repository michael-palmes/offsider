import Foundation
import OffsiderCore
import Testing
@testable import OffsiderAndroid

@Suite("Panel rotation")
struct PanelRotationTests {
    static let width = 1080
    static let height = 2424

    static func panel(_ x: Double, _ y: Double, rotation: Int) -> [Int32] {
        let point = PanelRotation.panelPoint(AndroidPoint(x: x, y: y), rotation: rotation, naturalWidth: width, naturalHeight: height)
        return [point.x, point.y]
    }

    @Test("the measured Settings taps: (570, 714) at rotation 1 and (428, 714) at rotation 3")
    func measuredPoints() {
        #expect(Self.panel(570, 714, rotation: 1) == [365, 570])
        #expect(Self.panel(428, 714, rotation: 3) == [714, 1995])
        #expect(Self.panel(525, 1050, rotation: 0) == [525, 1050])
    }

    @Test("every rotation agrees with the iOS orientation math within one pixel", arguments: [0, 1, 2, 3])
    func matchesOrientationMath(rotation: Int) {
        let orientation = AndroidDisplayGeometry(
            naturalWidth: Self.width, naturalHeight: Self.height,
            logicalWidth: rotation % 2 == 0 ? Self.width : Self.height,
            logicalHeight: rotation % 2 == 0 ? Self.height : Self.width,
            rotation: rotation, densityDpi: 420, hasSizeOverride: false
        ).orientation
        for (x, y) in [(10.0, 20.0), (500.0, 300.0), (1000.0, 1070.0)] {
            let android = Self.panel(x, y, rotation: rotation)
            let ios = OrientationCoordinateMath.translateToPhysical(
                x: x, y: y, orientation: orientation, portraitWidth: Double(Self.width), portraitHeight: Double(Self.height)
            )
            #expect(abs(Double(android[0]) - ios.x) <= 1 && abs(Double(android[1]) - ios.y) <= 1, "\(orientation) at (\(x), \(y))")
        }
    }

    @Test("points round to whole pixels and clamp to the panel")
    func roundsAndClamps() {
        #expect(Self.panel(100.6, 200.4, rotation: 0) == [101, 200])
        #expect(Self.panel(-5, 3000, rotation: 0) == [0, 2423])
        #expect(Self.panel(2500, -1, rotation: 1) == [1079, 2423])
    }

    @Test("screenshot turns are the guest's rotation minus the emulator's, in quarter turns", arguments: [
        (0, 0, 0), (1, 0, 1), (3, 0, 3), (3, 3, 0), (0, 3, 1), (2, 0, 2), (1, 3, 2),
    ])
    func screenshotTurns(guest: Int, emulator: Int, turns: Int) {
        #expect(PanelRotation.screenshotTurns(guestRotation: guest, emulatorRotation: emulator) == turns)
    }
}
