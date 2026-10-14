import Foundation
import OffsiderCore
import Testing
@testable import Offsider

@Suite("Simulator orientation reader")
@MainActor
struct SimulatorOrientationReaderTests {
    @Test("SimulatorKit's uiOrientation values map to the four orientations; anything else is unknown")
    func mapping() {
        #expect(SimulatorOrientationReader.mapUIOrientation(1) == .portrait)
        #expect(SimulatorOrientationReader.mapUIOrientation(2) == .portraitUpsideDown)
        #expect(SimulatorOrientationReader.mapUIOrientation(3) == .landscape)
        #expect(SimulatorOrientationReader.mapUIOrientation(4) == .landscapeFlipped)
        #expect(SimulatorOrientationReader.mapUIOrientation(0) == nil)
        #expect(SimulatorOrientationReader.mapUIOrientation(5) == nil)
    }

    @Test("the guarded encodings are Xcode 27's, with the screen id an unsigned 32-bit value")
    func encodings() {
        #expect(SimulatorOrientationReader.Encodings.initWithDeviceScreenID == PrivateAPIGuard.strippedEncoding("@28@0:8@16I24"))
        #expect(SimulatorOrientationReader.Encodings.alloc == PrivateAPIGuard.strippedEncoding("@16@0:8"))
        #expect(SimulatorOrientationReader.Encodings.screen == PrivateAPIGuard.strippedEncoding("@16@0:8"))
    }
}
