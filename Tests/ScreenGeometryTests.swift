import Foundation
import Testing
import OffsiderCore

@Suite("Screen Geometry")
struct ScreenGeometryTests {
    @Test("A region parses from x,y,width,height")
    func parsesRegion() throws {
        #expect(try PointRegion.parse("10,20,30,40") == PointRegion(x: 10, y: 20, width: 30, height: 40))
        #expect(try PointRegion.parse(" 0.5, 1 ,2.25,3") == PointRegion(x: 0.5, y: 1, width: 2.25, height: 3))
    }

    @Test("A malformed region is rejected with the expected shape", arguments: ["10,20,30", "10,20,30,40,50", "a,b,c,d", "", "10,,30,40"])
    func rejectsMalformed(text: String) {
        #expect {
            try PointRegion.parse(text)
        } throws: { error in
            "\(error)".contains("x,y,width,height")
        }
    }

    @Test("A negative origin or an empty size is rejected")
    func rejectsNegativeAndEmpty() {
        #expect { try PointRegion.parse("-1,0,10,10") } throws: { "\($0)".contains("negative") }
        #expect { try PointRegion.parse("0,0,0,10") } throws: { "\($0)".contains("greater than 0") }
    }

    @Test("Pixels per point holds whether or not the image matches the screen's orientation")
    func pixelsPerPoint() {
        #expect(ScreenGeometry.pixelsPerPoint(imageWidth: 1206, imageHeight: 2622, screenWidth: 402, screenHeight: 874) == 3)
        #expect(ScreenGeometry.pixelsPerPoint(imageWidth: 1206, imageHeight: 2622, screenWidth: 874, screenHeight: 402) == 3)
        #expect(ScreenGeometry.pixelsPerPoint(imageWidth: 1206, imageHeight: 2622, screenWidth: 0, screenHeight: 0) == nil)
    }

    @Test("Fractional points round outward to whole pixels")
    func roundsOutward() throws {
        let rect = try ScreenGeometry.pixelRect(
            for: PointRegion(x: 10.2, y: 20.5, width: 30.1, height: 40), pixelsPerPoint: 3, imageWidth: 1206, imageHeight: 2622
        )
        #expect(rect == PixelRect(x: 30, y: 61, width: 91, height: 121))
    }

    @Test("A region past the edge is clamped to the image")
    func clampsToImage() throws {
        let rect = try ScreenGeometry.pixelRect(
            for: PointRegion(x: 380, y: 850, width: 50, height: 50), pixelsPerPoint: 3, imageWidth: 1206, imageHeight: 2622
        )
        #expect(rect == PixelRect(x: 1140, y: 2550, width: 66, height: 72))
    }

    @Test("A region wholly outside the screen names the screen size in points")
    func outsideThrows() {
        #expect {
            try ScreenGeometry.pixelRect(
                for: PointRegion(x: 10, y: 900, width: 50, height: 50), pixelsPerPoint: 3, imageWidth: 1206, imageHeight: 2622
            )
        } throws: { error in
            "\(error)" == "--region 10,900,50,50 lies outside the 402 x 874 pt screen. Take coordinates from describe-ui."
        }
    }

    @Test("An absurdly large region fails as outside the screen instead of trapping", arguments: ["1e300,0,10,10", "0,1e300,10,10", "1e308,1e308,1e308,1e308"])
    func hugeRegionThrows(text: String) throws {
        let region = try PointRegion.parse(text)
        #expect(throws: ScreenRegionError.self) {
            try ScreenGeometry.pixelRect(for: region, pixelsPerPoint: 3, imageWidth: 1206, imageHeight: 2622)
        }
    }

    @Test("A huge size from a valid origin is clamped to the image")
    func hugeSizeClamps() throws {
        let rect = try ScreenGeometry.pixelRect(
            for: try PointRegion.parse("0,0,1e300,1e300"), pixelsPerPoint: 3, imageWidth: 1206, imageHeight: 2622
        )
        #expect(rect == PixelRect(x: 0, y: 0, width: 1206, height: 2622))
    }
}
