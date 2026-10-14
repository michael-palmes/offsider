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

    @Test("the probe's last line carries the API level, which neither changes the geometry nor is required")
    func apiLevelLine() throws {
        let probe = Self.probe(rotation: 0, frame: "[0, 0, 1080, 2424]")
        #expect(AndroidDisplayGeometry.apiLevel(in: probe + "\nAPI level: 28\n") == 28)
        #expect(try AndroidDisplayGeometry.parse(probe + "\nAPI level: 28\n") == AndroidDisplayGeometry.parse(probe))
        #expect(AndroidDisplayGeometry.apiLevel(in: probe + "\nAPI level: \n") == nil)
        #expect(AndroidDisplayGeometry.apiLevel(in: probe) == nil)
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

    @Test("with several viewport lines, the first one counts")
    func firstViewportWins() throws {
        let output = Self.probe(rotation: 1, frame: "[0, 0, 2424, 1080]")
            + "\n  Viewport INTERNAL: displayId=0, uniqueId=local:1, orientation=0, logicalFrame=[0, 0, 1080, 2424], isActive=[1]\n"
        let geometry = try AndroidDisplayGeometry.parse(output)
        #expect(geometry.rotation == 1)
        #expect(geometry.logicalWidth == 2424)
    }

    @Test("Android 9's plain viewport line gives the geometry in portrait")
    func android9Portrait() throws {
        let geometry = try AndroidDisplayGeometry.parse(Android9Fixtures.portraitProbe)
        #expect(geometry == AndroidDisplayGeometry(
            naturalWidth: 1080, naturalHeight: 2280, logicalWidth: 1080, logicalHeight: 2280, rotation: 0, densityDpi: 440, hasSizeOverride: false
        ))
        #expect(geometry.scale == 2.75)
    }

    @Test("Android 9 turned a quarter swaps the logical size and keeps the panel's")
    func android9Turned() throws {
        let geometry = try AndroidDisplayGeometry.parse(Android9Fixtures.turnedProbe)
        #expect(geometry.rotation == 1)
        #expect(geometry.logicalWidth == 2280)
        #expect(geometry.logicalHeight == 1080)
        #expect(geometry.naturalWidth == 1080)
        #expect(geometry.orientation == .landscapeFlipped)
    }

    @Test("an INTERNAL viewport line wins over a plain one, wherever it appears", arguments: [true, false])
    func internalWins(internalFirst: Bool) throws {
        let internalLine = "  Viewport INTERNAL: displayId=0, uniqueId=local:1, orientation=1, logicalFrame=[0, 0, 2424, 1080], isActive=[1]"
        let plainLine = "  Viewport: displayId=0, orientation=0, logicalFrame=[0, 0, 1080, 2424], physicalFrame=[0, 0, 1080, 2424], deviceSize=[1080, 2424]"
        let lines = internalFirst ? [internalLine, plainLine] : [plainLine, internalLine]
        let geometry = try AndroidDisplayGeometry.parse((["Physical size: 1080x2424", "Physical density: 420"] + lines).joined(separator: "\n"))
        #expect(geometry.rotation == 1)
        #expect(geometry.logicalWidth == 2424)
    }

    @Test("Android 9's viewport names no panel, so there is no unique id")
    func android9HasNoUniqueId() {
        #expect(AndroidDisplayGeometry.viewportUniqueId(in: Android9Fixtures.portraitProbe) == nil)
    }

    static func display(width: Int, height: Int, rotation: Int?, physical: (Int, Int)? = (1080, 2424), density: Int = 420) -> HelperDisplay {
        HelperDisplay(
            source: "DisplayManagerGlobal", logicalWidthPx: width, logicalHeightPx: height, rotation: rotation,
            physicalWidthPx: physical?.0, physicalHeightPx: physical?.1, densityDpi: density
        )
    }

    @Test("the helper's display gives the same geometry as the shell probe, without running it")
    func fromHelperDisplay() throws {
        let fromHelper = try #require(AndroidDisplayGeometry(display: Self.display(width: 1080, height: 2424, rotation: 0)))
        #expect(fromHelper == (try AndroidDisplayGeometry.parse(Self.probe(rotation: 0, frame: "[0, 0, 1080, 2424]"))))
    }

    @Test("rotation 1 from the helper keeps the swapped logical size and the panel's natural size")
    func fromHelperRotated() throws {
        let geometry = try #require(AndroidDisplayGeometry(display: Self.display(width: 2424, height: 1080, rotation: 1)))
        #expect(geometry.logicalWidth == 2424)
        #expect(geometry.naturalWidth == 1080)
        #expect(geometry.naturalHeight == 2424)
        #expect(geometry.orientation == .landscapeFlipped)
        #expect(!geometry.hasSizeOverride)
    }

    @Test("a logical size that differs from the display mode's is a size override")
    func fromHelperOverride() throws {
        let geometry = try #require(AndroidDisplayGeometry(display: Self.display(width: 720, height: 1616, rotation: 0)))
        #expect(geometry.hasSizeOverride)
        #expect(geometry.naturalWidth == 1080)
    }

    @Test("without a rotation (the helper's fallback read) there is no geometry, so the shell probe runs")
    func fromHelperWithoutRotation() {
        #expect(AndroidDisplayGeometry(display: Self.display(width: 1080, height: 2424, rotation: nil, physical: nil)) == nil)
    }
}
