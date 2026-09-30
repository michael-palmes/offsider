import Foundation
import OffsiderCore
import Testing
@testable import OffsiderAndroid

@Suite("Android display geometry")
struct AndroidDisplayGeometryTests {
    private static func probe(rotation: Int, frame: String, extra: String = "") -> String {
        """
        Physical size: 1080x2424
        \(extra)Physical density: 420
          Viewport INTERNAL: displayId=0, uniqueId=local:4619827259835644672, port=Optional(0), orientation=\(rotation), logicalFrame=\(frame), physicalFrame=[0, 0, 1080, 2424], deviceSize=[1080, 2424], isActive=[1]
        """
    }

    @Test("portrait: logical size is the panel size and the scale is density over 160")
    func portrait() throws {
        let geometry = try AndroidDisplayGeometry.parse(Self.probe(rotation: 0, frame: "[0, 0, 1080, 2424]"))
        #expect(geometry.naturalWidth == 1080)
        #expect(geometry.naturalHeight == 2424)
        #expect(geometry.logicalWidth == 1080)
        #expect(geometry.logicalHeight == 2424)
        #expect(geometry.scale == 2.625)
        #expect(geometry.orientation == .portrait)
    }

    @Test("rotation 1 and 3 swap the logical size and name the iOS orientation for the same turn", arguments: [
        (1, OrientationCoordinateMath.Orientation.landscapeFlipped), (3, .landscape), (2, .portraitUpsideDown),
    ])
    func rotated(rotation: Int, orientation: OrientationCoordinateMath.Orientation) throws {
        let frame = rotation == 2 ? "[0,0,1080,2424]" : "[0,0,2424,1080]"
        let geometry = try AndroidDisplayGeometry.parse(Self.probe(rotation: rotation, frame: frame))
        #expect(geometry.rotation == rotation)
        #expect(geometry.orientation == orientation)
        #expect(geometry.naturalWidth == 1080)
        #expect(geometry.logicalWidth == (rotation == 2 ? 1080 : 2424))
    }

    @Test("an override density wins over the physical one, and an override size is flagged")
    func overrides() throws {
        let output = Self.probe(rotation: 0, frame: "[0, 0, 1080, 2424]", extra: "Override size: 900x2000\nOverride density: 480\n")
        let geometry = try AndroidDisplayGeometry.parse(output)
        #expect(geometry.densityDpi == 480)
        #expect(geometry.hasSizeOverride)
        #expect(geometry.naturalWidth == 1080)
    }

    @Test("output without a viewport line throws with its first line", arguments: [
        ("Physical size: 1080x2424\nPhysical density: 420\n", "Physical size: 1080x2424"),
        ("/system/bin/sh: wm: not found\n", "/system/bin/sh: wm: not found"),
        ("", "no output"),
    ])
    func unparseable(output: String, firstLine: String) {
        let error = #expect(throws: AndroidDisplayGeometry.Unparseable.self) {
            try AndroidDisplayGeometry.parse(output)
        }
        #expect(error?.firstLine == firstLine)
    }
}
