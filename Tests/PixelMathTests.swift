import Foundation
import OffsiderCore
import Testing
@testable import OffsiderAndroid

@Suite("Pixel math")
struct PixelMathTests {
    @Test("rounding to a pixel never traps: NaN is 0 and huge values clamp to Int32", arguments: [
        (Double.nan, 0), (.infinity, Int(Int32.max)), (-.infinity, Int(Int32.min)), (1e19, Int(Int32.max)), (-1e19, Int(Int32.min)), (2.5, 3), (-2.4, -2),
    ])
    func roundedPixel(value: Double, expected: Int) {
        #expect(PixelMath.roundedPixel(value) == expected)
    }

    @Test("a side is 1 to maxSide pixels")
    func sides() {
        #expect(PixelMath.isSide(1) && PixelMath.isSide(PixelMath.maxSide))
        #expect(!PixelMath.isSide(0) && !PixelMath.isSide(PixelMath.maxSide + 1) && !PixelMath.isSide(-1))
    }

    @Test("byte counts refuse sides past maxSide and products that overflow")
    func byteCount() {
        #expect(PixelMath.byteCount(width: 1080, height: 2400) == 1080 * 2400 * 4)
        #expect(PixelMath.byteCount(width: PixelMath.maxSide + 1, height: 1) == nil)
        #expect(PixelMath.byteCount(width: 2, height: 2, bytesPerPixel: Int.max) == nil)
    }

    @Test("an infinite or huge point on Android clamps to the panel instead of trapping")
    func panelPointClamps() {
        let far = PanelRotation.panelPoint(AndroidPoint(x: .infinity, y: -1e19), rotation: 1, naturalWidth: 1080, naturalHeight: 2400)
        #expect(far.x >= 0 && far.x < 1080 && far.y >= 0 && far.y < 2400)
        let nan = PanelRotation.panelPoint(AndroidPoint(x: .nan, y: .nan), rotation: 0, naturalWidth: 1080, naturalHeight: 2400)
        #expect(nan.x == 0 && nan.y == 0)
    }

    private static let probe = """
    Physical size: 1080x2400
    Physical density: 420
    Viewport INTERNAL: displayId=0, uniqueId=local:1, port=0, orientation=0, logicalFrame=[0, 0, 1080, 2400], physicalFrame=[0, 0, 1080, 2400]
    """

    @Test("display sizes past maxSide are refused with the line that named them", arguments: [
        probe.replacingOccurrences(of: "Physical size: 1080x2400", with: "Physical size: 99999999999999999999x2400"),
        probe.replacingOccurrences(of: "Physical size: 1080x2400", with: "Physical size: 1080x16385"),
        probe.replacingOccurrences(of: "logicalFrame=[0, 0, 1080, 2400]", with: "logicalFrame=[-9223372036854775807, 0, 9223372036854775807, 2400]"),
        probe.replacingOccurrences(of: "Physical density: 420", with: "Physical density: 9223372036854775807"),
    ])
    func oversizedDisplay(output: String) {
        let error = #expect(throws: AndroidDisplayGeometry.Unparseable.self) { try AndroidDisplayGeometry.parse(output) }
        #expect(error?.firstLine.isEmpty == false)
    }

    @Test("a side over maxSide names the limit in the error")
    func oversizedNamesLimit() {
        let output = Self.probe.replacingOccurrences(of: "1080x2400", with: "1080x16385")
        let error = #expect(throws: AndroidDisplayGeometry.Unparseable.self) { try AndroidDisplayGeometry.parse(output) }
        #expect(error?.firstLine == "Physical size: 1080x16385: a side is over 16384 pixels")
    }

    @Test("an ordinary display still parses")
    func ordinaryDisplay() throws {
        let geometry = try AndroidDisplayGeometry.parse(Self.probe)
        #expect(geometry.naturalWidth == 1080 && geometry.logicalHeight == 2400 && geometry.densityDpi == 420)
    }
}
