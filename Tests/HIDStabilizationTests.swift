import Testing
import OffsiderCore
@testable import Offsider

@Suite("HID Stabilisation Tests")
struct HIDStabilizationTests {
    @Test("Unset uses the 25 ms default")
    func unsetUsesDefault() {
        let resolved = HIDStabilization.resolve(environmentValue: nil)
        #expect(resolved.milliseconds == 25)
        #expect(resolved.source == .defaultValue)
    }

    @Test("A value within range is used as given, including zero")
    func valueInRangeIsUsed() {
        #expect(HIDStabilization.resolve(environmentValue: "250") == (250, .environment))
        #expect(HIDStabilization.resolve(environmentValue: "0") == (0, .environment))
        #expect(HIDStabilization.resolve(environmentValue: "1000") == (1000, .environment))
    }

    @Test("A value above the cap is clamped to 1000 ms")
    func largeValueIsClamped() {
        #expect(HIDStabilization.resolve(environmentValue: "5000") == (1000, .clamped))
    }

    @Test("A value that is not a whole number is ignored")
    func invalidValueIsIgnored() {
        for value in ["abc", "-5", "12.5", ""] {
            #expect(HIDStabilization.resolve(environmentValue: value) == (25, .ignored))
        }
    }

    @Test("Input commands settle for the same delay doctor reports")
    @MainActor
    func interactorUsesSharedResolution() {
        for value in ["abc", "5000", "0", "40"] {
            let environment = ["OFFSIDER_HID_STABILIZATION_MS": value]
            #expect(HIDInteractor.stabilizationDelayMs(environment: environment) == HIDStabilization.resolve(environmentValue: value).milliseconds)
        }
        #expect(HIDInteractor.stabilizationDelayMs(environment: [:]) == 25)
    }
}
