import CoreGraphics
import Foundation
import Testing
import OffsiderCore
@testable import Offsider

@Suite("Screenshot Compare")
struct ScreenshotCompareTests {
    private let portrait = UIScreenInfo(width: 402, height: 874, scale: 3, rotation: .portrait)
    private let landscape = UIScreenInfo(width: 874, height: 402, scale: 3, rotation: .landscape)

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

    @Test("iOS landscape captures are turned upright and accept a region")
    func landscapeRegion() throws {
        let screen = try capture(TestImages.make(width: 1206, height: 2622), screen: landscape)
        #expect(screen.upright)
        #expect(screen.image.width == 2622 && screen.image.height == 1206)
        #expect(screen.pixelsPerPoint == 3)
        #expect(screen.untouchedPNG == nil)
        let rendered = try ScreenCapture.render(screen, request: ScreenshotRequest(region: PointRegion(x: 800, y: 0, width: 74, height: 10)))
        #expect(rendered.image.width == 222 && rendered.image.height == 30)
    }

    @Test("Turning an iOS capture upright brings each physical pixel back to its logical point", arguments: OrientationCoordinateMath.Orientation.allCases)
    func uprightRotationMatchesCoordinateMath(orientation: OrientationCoordinateMath.Orientation) throws {
        let portraitWidth = 40
        let portraitHeight = 60
        let logical = (x: 7, y: 3)
        let physical = OrientationCoordinateMath.translateToPhysical(
            x: Double(logical.x) + 0.5, y: Double(logical.y) + 0.5,
            orientation: orientation, portraitWidth: Double(portraitWidth), portraitHeight: Double(portraitHeight)
        )
        let image = TestImages.make(width: portraitWidth, height: portraitHeight, marked: [(x: Int(physical.x), y: Int(physical.y))])
        let size = orientation.isLandscape ? (portraitHeight, portraitWidth) : (portraitWidth, portraitHeight)
        let screen = try capture(image, screen: UIScreenInfo(width: Double(size.0), height: Double(size.1), scale: 1, rotation: orientation))

        let marked = TestImages.markedPixels(screen.image)
        #expect(marked.count == 1)
        #expect(marked.first?.x == logical.x && marked.first?.y == logical.y)
    }

    @Test("An iOS capture whose shape disagrees with the screen is not upright and refuses a region")
    func unreadOrientationRefusesRegion() throws {
        let screen = try capture(TestImages.make(width: 1206, height: 2622), screen: UIScreenInfo(width: 874, height: 402, scale: 3, rotation: nil))
        #expect(!screen.upright)
        #expect {
            try ScreenCapture.render(screen, request: ScreenshotRequest(region: PointRegion(x: 0, y: 0, width: 100, height: 100)))
        } throws: { "\($0)".contains("--region needs the screen's orientation") }
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
        #expect(line == #"{"path":"/tmp/a.png","width":402,"height":50,"pixelsPerPoint":1,"region":{"x":0,"y":100,"width":402,"height":50},"orientation":"portrait","rotation":0,"display":{"id":"main","platformId":"1"},"posture":null,"upright":true,"format":"png"}"#)
    }

    @Test("The JSON report names a foldable's display and posture")
    func foldableReport() throws {
        let cover = UIScreenInfo(
            width: 466, height: 678, scale: 3, rotation: .portrait, rotationDegrees: 0,
            display: ScreenDisplay(id: "cover", platformId: "1"), posture: .closed
        )
        let screen = try capture(TestImages.make(width: 1398, height: 2034), screen: cover)
        let line = try ScreenCapture.render(screen, request: ScreenshotRequest()).report(path: nil, format: nil, capture: screen).jsonLine()
        #expect(line == #"{"path":null,"width":1398,"height":2034,"pixelsPerPoint":3,"region":null,"orientation":"portrait","rotation":0,"display":{"id":"cover","platformId":"1"},"posture":"closed","upright":true,"format":null}"#)
    }

    @Test("simctl's capture of the unfolded Duo's inner display arrives upright: 2853 x 2007 px for a 951 x 669 pt screen, not turned")
    func innerDisplayCapture() throws {
        let inner = UIScreenInfo(
            width: 951, height: 669, scale: 3, rotation: .landscape, rotationDegrees: 0,
            display: ScreenDisplay(id: "inner", platformId: "3"), posture: .open, captureArrivesUpright: true
        )
        let image = TestImages.make(width: 2853, height: 2007, marked: [(x: 2700, y: 100)])
        let screen = try capture(image, screen: inner)
        let report = try ScreenCapture.render(screen, request: ScreenshotRequest(scale: .points)).report(path: nil, format: nil, capture: screen)

        #expect(screen.upright)
        #expect(screen.untouchedPNG != nil)
        #expect(TestImages.markedPixels(screen.image).map { [$0.x, $0.y] } == [[2700, 100]])
        #expect(report.jsonLine() == #"{"path":null,"width":951,"height":669,"pixelsPerPoint":1,"region":null,"orientation":"landscape","rotation":0,"display":{"id":"inner","platformId":"3"},"posture":"open","upright":true,"format":null}"#)
    }

    // MARK: - Pixel diff

    @Test("one changed pixel counts as one, with a 1 x 1 bounds")
    func onePixel() throws {
        let diff = try ScreenDiff.compare(baseline: TestImages.make(width: 40, height: 30), current: TestImages.make(width: 40, height: 30, marked: [(7, 9)]))
        #expect(diff.changedPixels == 1)
        #expect(diff.comparedPixels == 1200)
        #expect(diff.bounds == PixelRect(x: 7, y: 9, width: 1, height: 1))
    }

    @Test("identical images change no pixels and have no bounds")
    func identical() throws {
        let diff = try ScreenDiff.compare(baseline: TestImages.make(width: 40, height: 30), current: TestImages.make(width: 40, height: 30))
        #expect(diff.changedPixels == 0)
        #expect(diff.bounds == nil)
    }

    @Test("rows in the excluded bands are neither counted nor compared, and show grey")
    func bandsNotCounted() throws {
        let diff = try ScreenDiff.compare(
            baseline: TestImages.make(width: 40, height: 30), current: TestImages.make(width: 40, height: 30, marked: [(5, 1), (5, 28)]),
            excludingTop: 3, excludingBottom: 4
        )
        #expect(diff.changedPixels == 0)
        #expect(diff.comparedPixels == 40 * 23)
        #expect(ScreenshotMaskTests.pixel(diff.image, 5, 1) == [128, 128, 128])
    }

    @Test("the diff image marks a changed pixel magenta and fades the rest toward white")
    func diffImageColours() throws {
        let diff = try ScreenDiff.compare(baseline: TestImages.make(width: 40, height: 30), current: TestImages.make(width: 40, height: 30, marked: [(7, 9)]))
        #expect(ScreenshotMaskTests.pixel(diff.image, 7, 9) == [255, 0, 255])
        #expect(ScreenshotMaskTests.pixel(diff.image, 20, 20) == [221, 221, 221])
    }

    /// A flat 256 x 512 screen; `noise` nudges every pixel up to 4 units, as a device stream does, and `caret` adds a 2 x 8 px black bar at (34, 80).
    private static func streamed(noise: Bool, caret: Bool) -> CGImage {
        let width = 256, height = 512
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                let nudge = noise ? UInt8((x * 7 + y * 13) % 5) : 0
                let black = caret && (34..<36).contains(x) && (80..<88).contains(y)
                bytes[offset] = black ? 0 : 120 + nudge
                bytes[offset + 1] = black ? 0 : 120 + nudge
                bytes[offset + 2] = black ? 0 : 120 - nudge
            }
        }
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )!
    }

    @Test("with a noise tolerance, pixels count by the tiles' 8 x 8 blocks: noise in every pixel counts none, and a caret marks its whole block")
    func toleranceCountsBlocks() throws {
        let baseline = try ScreenImage.encode(Self.streamed(noise: false, caret: false), as: .png)
        let screen = try capture(Self.streamed(noise: true, caret: true), screen: nil)
        let (result, diffImage) = try ScreenCapture.comparison(
            try ScreenCapture.render(screen, request: ScreenshotRequest()), capture: screen, baseline: baseline, baselinePath: "base.png",
            bands: ScreenBands(top: 0, bottom: 0, noiseTolerance: 6), threshold: 0
        )

        #expect(result.changedTiles == 1)
        #expect(result.pixels == ScreenCompare.PixelCounts(changedPixels: 64, comparedPixels: 256 * 512, bounds: PixelRect(x: 32, y: 80, width: 8, height: 8)))
        #expect(ScreenshotMaskTests.pixel(diffImage, 39, 87) == [255, 0, 255])
        #expect(ScreenshotMaskTests.pixel(diffImage, 40, 87) != [255, 0, 255])
        #expect(ScreenshotMaskTests.pixel(diffImage, 101, 300) != [255, 0, 255])
    }

    @Test("a compare reports changed pixels and their bounds after the tile keys, and the diff image is written only when asked")
    @MainActor
    func diffOutputWritten() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("offsider-diff-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let baselinePath = directory.appendingPathComponent("before.png").path
        try ScreenImage.encode(TestImages.make(width: 1206, height: 2622), as: .png).write(to: URL(fileURLWithPath: baselinePath))
        let device = DeviceID(rawValue: "fake-device", platform: .ios)
        let backend = FakeDeviceBackend(
            trees: [], screenshots: [try ScreenImage.encode(TestImages.make(width: 1206, height: 2622, marked: [(600, 1500)]), as: .png)], screen: portrait
        )

        for wantsDiff in [false, true] {
            let arguments = ["--compare", baselinePath, "--device", device.rawValue] + (wantsDiff ? ["--diff-output", directory.path] : [])
            let command = try Screenshot.parse(arguments)
            let report = try await command.take(try command.request(), on: DeviceRouter.Route(backend: backend, device: device), masks: .none)
            let line = report.jsonLine()

            #expect(line.contains(#""changedPixels":1,"comparedPixels":"#))
            #expect(line.contains(#""changedBounds":{"x":600,"y":1500,"width":1,"height":1}"#))
            #expect(report.comparison?.summary.hasSuffix(", 1 pixel") == true)
            #expect((report.diffPath != nil) == wantsDiff)
            #expect(line.contains("diffPath") == wantsDiff)
            if let diffPath = report.diffPath {
                #expect(diffPath.hasPrefix(directory.path + "/Screenshot Diff - "))
                #expect(try ScreenImage.decode(try Data(contentsOf: URL(fileURLWithPath: diffPath))).width == 1206)
            }
        }
    }

    @Test("a baseline of another size writes no diff")
    @MainActor
    func mismatchWritesNoDiff() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("offsider-diff-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let baselinePath = directory.appendingPathComponent("before.png").path
        try ScreenImage.encode(TestImages.make(width: 100, height: 100), as: .png).write(to: URL(fileURLWithPath: baselinePath))
        let device = DeviceID(rawValue: "fake-device", platform: .ios)
        let backend = FakeDeviceBackend(trees: [], screenshots: [try ScreenImage.encode(TestImages.make(width: 1206, height: 2622), as: .png)], screen: portrait)
        let diffPath = directory.appendingPathComponent("diff.png").path
        let command = try Screenshot.parse(["--compare", baselinePath, "--diff-output", diffPath, "--device", device.rawValue])

        await #expect(throws: CLIError.self) {
            try await command.take(try command.request(), on: DeviceRouter.Route(backend: backend, device: device), masks: .none)
        }
        #expect(!FileManager.default.fileExists(atPath: diffPath))
    }

    @Test("--diff-output needs --compare and a PNG path", arguments: ["--diff-output d.png", "--compare b.png --diff-output d.jpg"])
    func diffOutputUsage(arguments: String) async throws {
        let result = try await TestHelpers.runOffsiderCommandSeparated("screenshot \(arguments) --device \(UUID().uuidString)")
        #expect(result.exitCode == 64)
        #expect(result.stderr.contains("--diff-output"))
    }
}

@Suite("Plain Android screenshot")
@MainActor
struct PlainScreenshotTests {
    @Test("a plain Android capture is written exactly as the device sent it, sized from its PNG header, without reading the screen")
    func plainWritesDeviceBytes() async throws {
        let png = try ScreenImage.encode(TestImages.make(width: 40, height: 80), as: .png)
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("offsider-plain-\(UUID().uuidString).png").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        let screen = UIScreenInfo(width: 20, height: 40, scale: 2, rotation: .portrait)
        func take(_ platform: DevicePlatform, plain: Bool, _ extra: [String] = []) async throws -> ScreenshotReport {
            let device = DeviceID(rawValue: platform == .android ? "emulator-5556" : "fake-device", platform: platform)
            let backend = FakeDeviceBackend(platform: platform, trees: [FakeUI.tree()], screenshots: [png], screen: screen)
            let command = try Screenshot.parse(["--output", path, "--device", device.rawValue] + extra)
            return try await command.take(try command.request(), on: DeviceRouter.Route(backend: backend, device: device), masks: .none, plain: plain)
        }

        let plain = try await take(.android, plain: true)
        #expect((plain.width, plain.height) == (40, 80))
        #expect(plain.orientation == nil && plain.display == nil)
        #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == png)

        #expect(try await take(.android, plain: false).orientation == "portrait")
        #expect(try await take(.ios, plain: true).orientation == "portrait")
        #expect(try await take(.android, plain: true, ["--scale", "0.5"]).orientation == "portrait")
    }

    @Test("the PNG header gives the size without decoding, and anything else gives none")
    func pngHeader() throws {
        let png = try ScreenImage.encode(TestImages.make(width: 3, height: 5), as: .png)
        #expect(PNGHeader.size(of: png).map { [$0.width, $0.height] } == [3, 5])
        #expect(PNGHeader.size(of: Data("not a png at all, just text".utf8)) == nil)
        #expect(PNGHeader.size(of: png.prefix(20)) == nil)
    }
}
