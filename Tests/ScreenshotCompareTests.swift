import CoreGraphics
import Foundation
import Testing
import OffsiderCore
@testable import Offsider

@Suite("Screenshot Compare")
struct ScreenshotCompareTests {
    private let portrait = UIScreenInfo(width: 402, height: 874, scale: 3, orientation: .portrait)
    private let landscape = UIScreenInfo(width: 874, height: 402, scale: 3, orientation: .landscape)

    private func capture(_ image: CGImage, platform: DevicePlatform = .ios, screen: UIScreenInfo?) throws -> CapturedScreen {
        try ScreenCapture.make(png: try ScreenImage.encode(image, as: .png), platform: platform, screen: screen)
    }

    @Test("The outcome is changed only above the threshold")
    func outcome() {
        #expect(ScreenCompare.outcome(changedFraction: 0.01, threshold: 0) == .changed)
        #expect(ScreenCompare.outcome(changedFraction: 0, threshold: 0) == .unchanged)
        #expect(ScreenCompare.outcome(changedFraction: 0.05, threshold: 0.05) == .unchanged)
        #expect(ScreenCompare.outcome(changedFraction: 0.06, threshold: 0.05) == .changed)
    }

    @Test("Summaries report tiles and a percentage")
    func summaries() {
        let changed = ScreenCompare.Result(changedTiles: 37, comparedTiles: 512, changedFraction: 37.0 / 512, outcome: .changed)
        #expect(changed.summary == "Changed: 37 of 512 tiles (7.2%)")
        let unchanged = ScreenCompare.Result(changedTiles: 0, comparedTiles: 512, changedFraction: 0, outcome: .unchanged)
        #expect(unchanged.summary == "Unchanged: 0 of 512 tiles")
    }

    @Test("--scale points turns a 3x capture into one pixel per point")
    func scalePoints() throws {
        let rendered = try ScreenCapture.render(
            try capture(TestImages.make(width: 1206, height: 2622), screen: portrait),
            request: ScreenshotRequest(scale: .points)
        )
        #expect(rendered.image.width == 402 && rendered.image.height == 874)
        #expect(rendered.pixelsPerPoint == 1)
    }

    @Test("A region is cropped in points before scaling, and reports the points it covers")
    func regionThenScale() throws {
        let rendered = try ScreenCapture.render(
            try capture(TestImages.make(width: 1206, height: 2622), screen: portrait),
            request: ScreenshotRequest(scale: .factor(0.5), region: PointRegion(x: 10, y: 100, width: 200, height: 50))
        )
        #expect(rendered.image.width == 300 && rendered.image.height == 75)
        #expect(rendered.pixelsPerPoint == 1.5)
        #expect(rendered.region == PointRegion(x: 10, y: 100, width: 200, height: 50))
    }

    @Test("A plain PNG capture is written byte for byte")
    func untouchedPassesThrough() throws {
        let screen = try capture(TestImages.make(width: 60, height: 120), screen: portrait)
        let rendered = try ScreenCapture.render(screen, request: ScreenshotRequest())
        #expect(try rendered.encoded(as: .png) == screen.untouchedPNG)
    }

    @Test("iOS landscape captures still scale to points but refuse a region")
    func landscapeRegionRefused() throws {
        let screen = try capture(TestImages.make(width: 1206, height: 2622), screen: landscape)
        #expect(!screen.upright)
        let scaled = try ScreenCapture.render(screen, request: ScreenshotRequest(scale: .points))
        #expect(scaled.image.width == 402 && scaled.image.height == 874)
        #expect {
            try ScreenCapture.render(screen, request: ScreenshotRequest(region: PointRegion(x: 0, y: 0, width: 100, height: 100)))
        } throws: { error in
            "\(error)" == "--region needs a portrait iOS screen for now: iOS screenshots are not rotated in landscape. Rotate the device to portrait, or capture the whole screen."
        }
    }

    @Test("Android landscape captures are upright and accept a region")
    func androidLandscapeRegion() throws {
        let screen = try capture(TestImages.make(width: 2622, height: 1206), platform: .android, screen: landscape)
        let rendered = try ScreenCapture.render(screen, request: ScreenshotRequest(region: PointRegion(x: 800, y: 0, width: 74, height: 10)))
        #expect(rendered.image.width == 222 && rendered.image.height == 30)
    }

    @Test("Without a screen size, points cannot be used")
    func noScreenSize() throws {
        let screen = try capture(TestImages.make(width: 60, height: 120), screen: nil)
        #expect(try ScreenCapture.render(screen, request: ScreenshotRequest(scale: .factor(0.5))).image.width == 30)
        #expect {
            try ScreenCapture.render(screen, request: ScreenshotRequest(scale: .points))
        } throws: { "\($0)".contains("did not report") }
    }

    @Test("A saved capture compares as unchanged with the same capture, and changed after an edit")
    func compareWithSavedBaseline() throws {
        let request = ScreenshotRequest(scale: .points)
        let before = try ScreenCapture.render(try capture(TestImages.make(width: 1206, height: 2622), screen: portrait), request: request)
        let baseline = try before.encoded(as: .png)

        let same = try ScreenCapture.compare(
            before, capture: try capture(TestImages.make(width: 1206, height: 2622), screen: portrait),
            baseline: baseline, baselinePath: "base.png", bands: ScreenBands(top: 60, bottom: 0), threshold: 0
        )
        #expect(same.outcome == .unchanged)
        #expect(same.changedTiles == 0)

        let afterScreen = try capture(TestImages.make(width: 1206, height: 2622, marked: [(600, 1500)]), screen: portrait)
        let after = try ScreenCapture.render(afterScreen, request: request)
        let changed = try ScreenCapture.compare(
            after, capture: afterScreen, baseline: baseline, baselinePath: "base.png", bands: ScreenBands(top: 60, bottom: 0), threshold: 0
        )
        #expect(changed.outcome == .changed)
        #expect(changed.changedTiles >= 1)
    }

    @Test("A change in the status bar band does not count as a change of the whole screen")
    func bandExcluded() throws {
        let request = ScreenshotRequest()
        let baseline = try ScreenCapture.render(try capture(TestImages.make(width: 1206, height: 2622), screen: portrait), request: request)
            .encoded(as: .png)
        let clockScreen = try capture(TestImages.make(width: 1206, height: 2622, marked: [(100, 30)]), screen: portrait)
        let result = try ScreenCapture.compare(
            try ScreenCapture.render(clockScreen, request: request), capture: clockScreen,
            baseline: baseline, baselinePath: "base.png", bands: ScreenBands(top: 60, bottom: 0), threshold: 0
        )
        #expect(result.outcome == .unchanged)
        #expect(result.comparedTiles < 512)
    }

    @Test("A baseline of another size is refused with both sizes")
    func sizeMismatch() throws {
        let baseline = try ScreenImage.encode(TestImages.make(width: 1206, height: 2622), as: .png)
        let screen = try capture(TestImages.make(width: 1206, height: 2622), screen: portrait)
        let rendered = try ScreenCapture.render(screen, request: ScreenshotRequest(scale: .points))
        #expect {
            try ScreenCapture.compare(rendered, capture: screen, baseline: baseline, baselinePath: "base.png", bands: ScreenBands(top: 0, bottom: 0), threshold: 0)
        } throws: { error in
            "\(error)" == "The baseline is 1206 x 2622 px but this capture is 402 x 874 px. Capture the baseline with the same --scale and --region."
        }
    }

    @Test("An unreadable baseline names its path")
    func unreadableBaseline() throws {
        let screen = try capture(TestImages.make(width: 60, height: 120), screen: portrait)
        let rendered = try ScreenCapture.render(screen, request: ScreenshotRequest())
        #expect {
            try ScreenCapture.compare(rendered, capture: screen, baseline: Data("x".utf8), baselinePath: "shots/base.png", bands: ScreenBands(top: 0, bottom: 0), threshold: 0)
        } throws: { "\($0)".contains("shots/base.png") }
        #expect { try ScreenCapture.readBaseline(at: "/nonexistent/base.png") } throws: { "\($0)".contains("/nonexistent/base.png") }
    }

    @Test("The format comes from --format, else the output extension, and --quality needs JPEG")
    func formatResolution() throws {
        #expect(try ScreenCapture.resolveFormat(named: nil, quality: nil, outputPath: nil) == .png)
        #expect(try ScreenCapture.resolveFormat(named: nil, quality: nil, outputPath: "shot.JPG") == .jpeg(quality: 85))
        #expect(try ScreenCapture.resolveFormat(named: "jpeg", quality: 60, outputPath: "shots/") == .jpeg(quality: 60))
        #expect { try ScreenCapture.resolveFormat(named: "png", quality: 60, outputPath: nil) } throws: {
            "\($0)" == "--quality applies to --format jpeg only."
        }
        #expect { try ScreenCapture.resolveFormat(named: "png", quality: nil, outputPath: "shot.jpg") } throws: { "\($0)".contains(".jpg") }
        #expect { try ScreenCapture.resolveFormat(named: "gif", quality: nil, outputPath: nil) } throws: { "\($0)".contains("png or jpeg") }
    }

    @Test("--scale takes points or a factor from 0.1 to 1")
    func scaleParsing() throws {
        #expect(try ScreenshotScale.parse("points") == .points)
        #expect(try ScreenshotScale.parse("0.5") == .factor(0.5))
        #expect(try ScreenshotScale.parse("1") == .native)
        #expect(throws: CLIError.self) { try ScreenshotScale.parse("2") }
        #expect(throws: CLIError.self) { try ScreenshotScale.parse("0.05") }
    }

    @Test("The JSON report lists the documented keys in order")
    func jsonReport() throws {
        let screen = try capture(TestImages.make(width: 1206, height: 2622), screen: portrait)
        let rendered = try ScreenCapture.render(screen, request: ScreenshotRequest(scale: .points, region: PointRegion(x: 0, y: 100, width: 402, height: 50)))
        let line = rendered.report(path: "/tmp/a.png", format: .png, capture: screen).jsonLine()
        #expect(line == #"{"path":"/tmp/a.png","width":402,"height":50,"pixelsPerPoint":1,"region":{"x":0,"y":100,"width":402,"height":50},"orientation":"portrait","upright":true,"format":"png"}"#)
    }
}
