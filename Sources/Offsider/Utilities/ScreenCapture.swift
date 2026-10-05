import CoreGraphics
import Foundation
import OffsiderCore

extension ImageFailure: UserFacingError {
    var userFacingDescription: String { description }
}

extension ScreenRegionError: UserFacingError {
    var userFacingDescription: String { message }
}

/// One screenshot with what is needed to map points to its pixels.
struct CapturedScreen {
    let image: CGImage
    let platform: DevicePlatform
    let screen: UIScreenInfo?
    /// Pixels per point of `image`; nil when the device did not report its screen size.
    let pixelsPerPoint: Double?
    /// False when the image's shape disagrees with the screen's points (an iOS orientation that could not be read).
    let upright: Bool
    /// The device's PNG, while `image` is still exactly what it decodes to.
    let untouchedPNG: Data?
}

enum ScreenshotScale: Equatable {
    case native
    case points
    case factor(Double)

    static func parse(_ text: String) throws -> ScreenshotScale {
        let trimmed = text.trimmingCharacters(in: .whitespaces).lowercased()
        if trimmed == "points" { return .points }
        guard let factor = Double(trimmed), factor >= 0.1, factor <= 1 else {
            throw CLIError(errorDescription: "--scale takes points or a factor from 0.1 to 1; got \"\(text)\".", reason: .usage)
        }
        return factor == 1 ? .native : .factor(factor)
    }
}

struct ScreenshotRequest {
    var scale: ScreenshotScale = .native
    var region: PointRegion?
    var format: ImageFormat = .png
}

/// The captured image after the request's crop and scale.
struct RenderedScreenshot {
    let image: CGImage
    /// Nil when the device did not report its screen size.
    let pixelsPerPoint: Double?
    /// The points actually covered after rounding outward to whole pixels.
    let region: PointRegion?
    let untouchedPNG: Data?

    func encoded(as format: ImageFormat) throws -> Data {
        if format == .png, let untouchedPNG { return untouchedPNG }
        return try ScreenImage.encode(image, as: format)
    }

    func report(path: String?, format: ImageFormat?, capture: CapturedScreen, comparison: ScreenCompare.Result? = nil, masks: ScreenCapture.MaskResult? = nil) -> ScreenshotReport {
        ScreenshotReport(
            path: path,
            width: image.width,
            height: image.height,
            pixelsPerPoint: pixelsPerPoint,
            region: region,
            orientation: capture.screen?.shape.rawValue,
            rotation: capture.screen?.resolvedRotationDegrees,
            display: capture.screen?.resolvedDisplay(on: capture.platform) ?? .main(on: capture.platform),
            posture: capture.screen?.posture,
            upright: capture.upright,
            format: format,
            comparison: comparison,
            maskedBy: masks?.painted,
            maskUnmatched: masks?.unmatched ?? []
        )
    }
}

@MainActor
enum ScreenCapture {
    static func capture(_ backend: any DeviceBackend, device: DeviceID) async throws -> CapturedScreen {
        let png = try await backend.screenshotPNG(for: device)
        let screen = try? await backend.screenInfo(for: device)
        return try make(png: png, platform: device.platform, screen: screen)
    }

    /// One chosen display; a display that is not active is captured as it is, with its native points.
    static func capture(_ capturer: any DisplayCapturing, device: DeviceID, display: DisplayInfo, posture: Posture?) async throws -> CapturedScreen {
        let png = try await capturer.screenshotPNG(for: device, display: display.descriptor.platformId)
        guard !display.active else {
            let screen = try? await capturer.screenInfo(for: device)
            return try make(png: png, platform: device.platform, screen: screen)
        }
        let descriptor = display.descriptor
        let screen = UIScreenInfo(
            width: descriptor.pointWidth, height: descriptor.pointHeight, scale: descriptor.scale,
            rotationDegrees: display.rotationDegrees, display: descriptor.screenDisplay, posture: posture
        )
        return try make(png: png, platform: device.platform, screen: screen)
    }

    /// idb's iOS framebuffer stays in the display's native orientation when the screen turns, so it is rotated here; simctl and Android captures arrive upright.
    nonisolated static func make(png: Data, platform: DevicePlatform, screen: UIScreenInfo?) throws -> CapturedScreen {
        let decoded = try ScreenImage.decode(png)
        let turns = platform == .ios && screen?.captureArrivesUpright != true
            ? (screen?.rotation?.uprightQuarterTurnsCounterclockwise ?? 0)
            : 0
        let image = try ScreenImage.rotated(decoded, quarterTurnsCounterclockwise: turns)
        let pixelsPerPoint = screen.flatMap {
            ScreenGeometry.pixelsPerPoint(imageWidth: image.width, imageHeight: image.height, screenWidth: $0.width, screenHeight: $0.height)
        }
        let upright = screen.map { (image.width >= image.height) == ($0.width >= $0.height) } ?? true
        return CapturedScreen(
            image: image, platform: platform, screen: screen, pixelsPerPoint: pixelsPerPoint, upright: upright,
            untouchedPNG: turns == 0 ? png : nil
        )
    }

    /// What masking painted: rectangles per kind asked for, and the selectors that matched nothing.
    struct MaskResult {
        let capture: CapturedScreen
        let painted: [MaskKind: Int]
        let unmatched: [String]
    }

    /// Paints every mask in `plan` black; a capture that is not upright cannot be mapped, so it is withheld.
    nonisolated static func masking(_ capture: CapturedScreen, plan: MaskPlan, tree: UITree?) throws -> MaskResult {
        var targets = MaskTargets()
        if let tree {
            targets = try plan.textTargets(in: tree)
            if plan.secure {
                targets.frames[.secure] = tree.secureFrames
            }
            for (kind, values) in [(MaskKind.id, plan.ids), (.label, plan.labels)] {
                for value in values {
                    let query: AccessibilityQuery = kind == .id ? .id(value) : .label(value)
                    let matches = AccessibilityTargetResolver.candidates(roots: tree.roots, query: query, elementType: nil).matches
                    targets.frames[kind, default: []] += matches.map(\.frame)
                    if matches.isEmpty {
                        targets.unmatched.append("--mask-\(kind.rawValue) \(value)")
                    }
                }
            }
        }
        targets.frames[.region] = plan.regions.map { UIFrame(x: $0.x, y: $0.y, width: $0.width, height: $0.height) }

        var image = capture.image
        var painted: [MaskKind: Int] = [:]
        for kind in plan.kinds {
            let rects = try SecureMask.pixelRects(
                frames: targets.frames[kind] ?? [],
                subject: subject(of: kind),
                pixelsPerPoint: capture.upright ? capture.pixelsPerPoint : nil,
                imageWidth: capture.image.width,
                imageHeight: capture.image.height
            )
            painted[kind] = rects.count
            if !rects.isEmpty {
                image = try ScreenImage.masked(image, pixelRects: rects)
            }
        }
        guard image !== capture.image else { return MaskResult(capture: capture, painted: painted, unmatched: targets.unmatched) }
        let masked = CapturedScreen(
            image: image, platform: capture.platform, screen: capture.screen, pixelsPerPoint: capture.pixelsPerPoint,
            upright: capture.upright, untouchedPNG: nil
        )
        return MaskResult(capture: masked, painted: painted, unmatched: targets.unmatched)
    }

    nonisolated private static func subject(of kind: MaskKind) -> String {
        switch kind {
        case .secure: "A secure field"
        case .id: "An element --mask-id matched"
        case .label: "An element --mask-label matched"
        case .text: "An element --mask-text matched"
        case .emails: "An email address"
        case .region: "A --mask-region"
        }
    }

    /// Crops to the region first, then scales.
    nonisolated static func render(_ capture: CapturedScreen, request: ScreenshotRequest) throws -> RenderedScreenshot {
        var image = capture.image
        var region: PointRegion?
        if let requested = request.region {
            guard capture.upright else {
                throw CLIError(errorDescription: "--region needs the screen's orientation, which the device did not report, so the capture may not be upright. Check with `offsider orientation`, or capture the whole screen.", reason: .orientationUnknown)
            }
            let pixelsPerPoint = try requirePixelsPerPoint(capture, for: "--region")
            let rect = try ScreenGeometry.pixelRect(for: requested, pixelsPerPoint: pixelsPerPoint, imageWidth: image.width, imageHeight: image.height)
            image = try ScreenImage.cropped(image, to: rect)
            region = ScreenGeometry.pointRegion(for: rect, pixelsPerPoint: pixelsPerPoint)
        }

        var pixelsPerPoint = capture.pixelsPerPoint
        let factor: Double
        switch request.scale {
        case .native:
            factor = 1
        case .points:
            factor = 1 / (try requirePixelsPerPoint(capture, for: "--scale points"))
        case .factor(let value):
            factor = value
        }
        if factor != 1 {
            let width = max(1, Int((Double(image.width) * factor).rounded()))
            let height = max(1, Int((Double(image.height) * factor).rounded()))
            image = try ScreenImage.scaled(image, width: width, height: height)
            pixelsPerPoint = pixelsPerPoint.map { $0 * factor }
        }
        let untouched = image === capture.image ? capture.untouchedPNG : nil
        return RenderedScreenshot(image: image, pixelsPerPoint: pixelsPerPoint, region: region, untouchedPNG: untouched)
    }

    /// Volatile bands in the rendered image's pixels: whole, upright screens, in portrait unless the bands hold in every orientation, as `--verify` does.
    nonisolated static func bandPixels(_ rendered: RenderedScreenshot, capture: CapturedScreen, bands: ScreenBands) -> (top: Int, bottom: Int) {
        guard rendered.region == nil, capture.upright, let screen = capture.screen, bands.everyOrientation || screen.height >= screen.width,
              let pixelsPerPoint = rendered.pixelsPerPoint else {
            return (0, 0)
        }
        return (Int((bands.top * pixelsPerPoint).rounded()), Int((bands.bottom * pixelsPerPoint).rounded()))
    }

    /// Fingerprints the rendered capture against a baseline image file with the same crop and scale, and counts its changed pixels.
    nonisolated static func compare(
        _ rendered: RenderedScreenshot,
        capture: CapturedScreen,
        baseline: Data,
        baselinePath: String,
        bands: ScreenBands,
        threshold: Double
    ) throws -> ScreenCompare.Result {
        try comparison(rendered, capture: capture, baseline: baseline, baselinePath: baselinePath, bands: bands, threshold: threshold).result
    }

    /// The tile verdict with pixel counts, and the diff image `--diff-output` writes.
    nonisolated static func comparison(
        _ rendered: RenderedScreenshot,
        capture: CapturedScreen,
        baseline: Data,
        baselinePath: String,
        bands: ScreenBands,
        threshold: Double
    ) throws -> (result: ScreenCompare.Result, diffImage: CGImage) {
        let baselineImage: CGImage
        do {
            baselineImage = try ScreenImage.decode(baseline)
        } catch {
            throw CLIError(errorDescription: "The baseline \(baselinePath) is not a readable image. Pass a PNG saved by offsider screenshot.", reason: .baselineUnreadable)
        }
        guard baselineImage.width == rendered.image.width, baselineImage.height == rendered.image.height else {
            throw CLIError(errorDescription: "The baseline is \(baselineImage.width) x \(baselineImage.height) px but this capture is \(rendered.image.width) x \(rendered.image.height) px. Capture the baseline with the same --scale and --region.", reason: .baselineMismatch)
        }
        let exclusion = bandPixels(rendered, capture: capture, bands: bands)
        guard let current = ImageFingerprint(image: rendered.image, excludingTopPixels: exclusion.top, excludingBottomPixels: exclusion.bottom),
              let before = ImageFingerprint(image: baselineImage, excludingTopPixels: exclusion.top, excludingBottomPixels: exclusion.bottom),
              var result = ScreenCompare.compare(before, current, threshold: threshold) else {
            throw ImageFailure(detail: "could not compare the capture with \(baselinePath)")
        }
        let diff = try ScreenDiff.compare(baseline: baselineImage, current: rendered.image, excludingTop: exclusion.top, excludingBottom: exclusion.bottom)
        result.pixels = ScreenCompare.PixelCounts(changedPixels: diff.changedPixels, comparedPixels: diff.comparedPixels, bounds: diff.bounds)
        return (result, diff.image)
    }

    /// Reads a baseline image, naming the path when it cannot.
    nonisolated static func readBaseline(at path: String) throws -> Data {
        let expanded = (path as NSString).expandingTildeInPath
        guard let data = FileManager.default.contents(atPath: expanded) else {
            throw CLIError(errorDescription: "Could not read the baseline image at \(expanded). Check the path, or capture one first with offsider screenshot --output \(path).", reason: .baselineUnreadable)
        }
        return data
    }

    /// An explicit `--format`, else the output extension (.jpg or .jpeg), else PNG.
    nonisolated static func resolveFormat(named name: String?, quality: Int?, outputPath: String?) throws -> ImageFormat {
        let pathExtension = outputPath.map { ($0 as NSString).pathExtension.lowercased() } ?? ""
        let extensionIsJPEG = pathExtension == "jpg" || pathExtension == "jpeg"
        let isJPEG: Bool
        switch name?.lowercased() {
        case nil:
            isJPEG = extensionIsJPEG
        case "png":
            isJPEG = false
        case "jpeg", "jpg":
            isJPEG = true
        case let other?:
            throw CLIError(errorDescription: "--format takes png or jpeg; got \"\(other)\".", reason: .usage)
        }
        if name != nil, (isJPEG && pathExtension == "png") || (!isJPEG && extensionIsJPEG) {
            throw CLIError(errorDescription: "--output ends in .\(pathExtension) but --format is \(isJPEG ? "jpeg" : "png"). Change the extension or the format.", reason: .usage)
        }
        guard let quality else { return isJPEG ? .jpeg(quality: ImageFormat.defaultJPEGQuality) : .png }
        guard isJPEG else {
            throw CLIError(errorDescription: "--quality applies to --format jpeg only.", reason: .usage)
        }
        guard (1...100).contains(quality) else {
            throw CLIError(errorDescription: "--quality must be from 1 to 100; got \(quality).", reason: .usage)
        }
        return .jpeg(quality: quality)
    }

    /// A directory or no path gets "<prefix> - <device> - <timestamp>.<ext>"; missing parent directories are created.
    nonisolated static func outputURL(path: String?, prefix: String, deviceName: String, format: ImageFormat, now: Date = Date()) throws -> URL {
        let fileManager = FileManager.default
        let generatedName = "\(prefix) - \(deviceName) - \(formatTimestamp(now)).\(format.fileExtension)"
        let providedPath = path?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedPath: String
        if let providedPath, !providedPath.isEmpty {
            resolvedPath = (providedPath as NSString).expandingTildeInPath
        } else {
            resolvedPath = generatedName
        }

        let baseURL = resolvedPath.hasPrefix("/")
            ? URL(fileURLWithPath: resolvedPath)
            : URL(fileURLWithPath: fileManager.currentDirectoryPath).appendingPathComponent(resolvedPath)

        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: baseURL.path, isDirectory: &isDirectory), isDirectory.boolValue {
            return baseURL.appendingPathComponent(generatedName)
        }

        let directoryURL = baseURL.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: directoryURL.path) {
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true, attributes: nil)
        }
        if fileManager.fileExists(atPath: baseURL.path) {
            try fileManager.removeItem(at: baseURL)
        }
        return baseURL
    }

    nonisolated private static func requirePixelsPerPoint(_ capture: CapturedScreen, for option: String) throws -> Double {
        guard let pixelsPerPoint = capture.pixelsPerPoint else {
            throw CLIError(errorDescription: "\(option) needs the screen size in points, which the device did not report. Capture the whole screen, or pass a factor such as --scale 0.5.", reason: .orientationUnknown)
        }
        return pixelsPerPoint
    }

    nonisolated private static func formatTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return formatter.string(from: date)
    }
}
