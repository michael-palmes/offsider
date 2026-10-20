import Foundation
import OffsiderCore
import OffsiderIOSDevice
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

    @Test("every call the reader casts is recorded, so doctor checks each one")
    func everyCallRecorded() {
        let recorded = SimulatorOrientationReader.Encodings.recorded.map(\.selector)
        #expect(recorded == ["initWithDevice:screenID:", "screen", "screenProperties", "uiOrientation"])
    }

    @Test("a reading whose declared types differ from the recorded ones is refused before the cast")
    func differingEncodingRefused() {
        let object = NSString(string: "x")
        #expect(throws: PrivateAPIChanged.self) {
            try PrivateAPIGuard.requireMessage(to: object, NSSelectorFromString("hash"), encoding: SimulatorOrientationReader.Encodings.uiOrientation, protocol: "NSObject", framework: "SimulatorKit")
        }
    }

    @Test("doctor fails naming the first changed selector, warns on a newer CoreDevice, else passes")
    func doctorRule() {
        let changed = PrivateAPIDoctorRule.Expectation(owner: "SimScreenProperties", isProtocol: true, selector: "uiOrientation", encoding: "I@:", framework: "SimulatorKit")
        let fail = PrivateAPIDoctorRule.verdict(checked: 5, changed: [changed, changed], coreDevice: nil)
        #expect(fail.status == .fail)
        #expect(fail.detail == "This Xcode's SimulatorKit changed uiOrientation (and 1 more), so Offsider will refuse that call")

        let newer = PrivateAPIDoctorRule.verdict(checked: 5, changed: [], coreDevice: CoreDeviceVersion(components: [CoreDeviceVersion.lastTestedMajor + 1, 2]))
        #expect(newer.status == .warn)
        #expect(newer.detail.contains("is newer than the last tested (\(CoreDeviceVersion.lastTestedMajor))"))

        let tested = PrivateAPIDoctorRule.verdict(checked: 5, changed: [], coreDevice: CoreDeviceVersion(components: [CoreDeviceVersion.lastTestedMajor, 99]))
        #expect(tested.status == .pass)
        #expect(tested.detail == "5 recorded types match this Xcode")
    }

    @Test("doctor reads a missing class or protocol as changed")
    func doctorMissing() {
        let gone = PrivateAPIDoctorRule.Expectation(owner: "NoSuchProtocol", isProtocol: true, selector: "uiOrientation", encoding: "I@:", framework: "SimulatorKit")
        #expect(PrivateAPIDoctorRule.installed(gone) == nil)
        let present = PrivateAPIDoctorRule.Expectation(owner: "NSObject", isProtocol: true, selector: "hash", encoding: "Q@:", framework: "Foundation")
        #expect(PrivateAPIDoctorRule.installed(present) == "Q@:")
    }
}
