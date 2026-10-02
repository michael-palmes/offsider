import Testing
@testable import OffsiderAndroid

@Suite("Android slider maths")
struct SliderMathTests {
    static func int(_ min: Double, _ max: Double) -> HelperRange {
        HelperRange(type: "int", min: min, max: max, current: min)
    }

    @Test("40 % of React Native's 0 to 10,000 SeekBar range sends 4,000")
    func reactNativeRange() {
        let target = SliderMath.target(fraction: 0.4, range: Self.int(0, 10_000))
        #expect(target.value == 4_000)
        #expect(target.reachable == 0.4)
    }

    @Test("40 % of a 0 to 15 volume range sends 6, which shows exactly 40 %")
    func volumeRange() {
        let target = SliderMath.target(fraction: 0.4, range: Self.int(0, 15))
        #expect(target.value == 6)
        #expect(target.reachable == 0.4)
    }

    @Test("an int range coarser than the request sends the nearest whole step and reports what it shows")
    func nearestStep() {
        let target = SliderMath.target(fraction: 0.7825, range: Self.int(0, 100))
        #expect(target.value == 78)
        #expect(target.reachable == 0.78)
    }

    @Test("float and percent ranges are not rounded")
    func notRounded() {
        let float = SliderMath.target(fraction: 0.7825, range: HelperRange(type: "float", min: 0, max: 1, current: 0))
        #expect(float.value == 0.7825)
        let percent = SliderMath.target(fraction: 0.7825, range: HelperRange(type: "percent", min: 0, max: 100, current: 0))
        #expect(abs(percent.value - 78.25) < 1e-9)
        #expect(abs(percent.reachable - 0.7825) < 1e-12)
    }

    @Test("a range that does not start at zero is offset from its minimum")
    func offsetRange() {
        let target = SliderMath.target(fraction: 0.5, range: Self.int(-10, 10))
        #expect(target.value == 0)
        #expect(target.reachable == 0.5)
    }

    @Test("fractions outside 0 to 1 are clamped to the ends of the range")
    func clamped() {
        #expect(SliderMath.target(fraction: -0.2, range: Self.int(0, 100)).value == 0)
        let high = SliderMath.target(fraction: 1.3, range: Self.int(0, 100))
        #expect(high.value == 100)
        #expect(high.reachable == 1)
    }
}
