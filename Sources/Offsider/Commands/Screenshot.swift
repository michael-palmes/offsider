import ArgumentParser
import Foundation
import OffsiderCore

struct Screenshot: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "screenshot",
        abstract: "Capture the device display as a PNG or JPEG, optionally cropped, scaled to points or compared with a baseline",
        discussion: """
        --scale points makes one image pixel one point, so image coordinates are tap coordinates. \
        --region takes points as describe-ui prints them; the crop happens before scaling. \
        --compare captures, applies the same --region and --scale, and exits 0 when more than \
        --threshold of the screen's tiles changed, or 5 when not. \
        --display captures one display of a foldable (see `offsider displays`); a display that is not active \
        is captured as it is, often dark.
        """
    )

    @OptionGroup
    var deviceOption: DeviceOption

    @OptionGroup
    var displayOption: DisplayOption

    @Option(help: "Output file path, or a directory for a generated name. Defaults to 'Simulator Screenshot - <device name> - <timestamp>.png' (iOS) or 'Emulator Screenshot - <AVD> - <timestamp>.png' (Android) in the current directory. With --compare, an image is written only when this is given.")
    var output: String?

    @Option(help: ArgumentHelp("'points' for one pixel per point (image coordinates equal tap coordinates), or a factor from 0.1 to 1.", valueName: "points|factor"))
    var scale: String?

    @Option(help: ArgumentHelp("Capture only this rectangle, in points as describe-ui prints them.", valueName: "x,y,w,h"))
    var region: String?

    @Option(help: ArgumentHelp("Image format. Inferred from a .jpg or .jpeg --output; defaults to png.", valueName: "png|jpeg"))
    var format: String?

    @Option(help: ArgumentHelp("JPEG quality from 1 to 100 (default 85). JPEG only.", valueName: "1-100"))
    var quality: Int?

    @Option(help: ArgumentHelp("Compare the capture with this baseline image, captured with the same --scale and --region.", valueName: "baseline"))
    var compare: String?

    @Option(help: ArgumentHelp("With --compare, the fraction of tiles that may change and still count as unchanged (0 to 1, default 0).", valueName: "0-1"))
    var threshold: Double?

    @Flag(name: .customLong("json"), help: "Print one JSON object to stdout; human text goes to stderr.")
    var json = false

    func validate() throws {
        do {
            _ = try request()
        } catch let error as UserFacingError {
            throw ValidationError(error.userFacingDescription)
        }
        if let threshold {
            guard compare != nil else { throw ValidationError("--threshold applies to --compare only.") }
            guard (0...1).contains(threshold) else { throw ValidationError("--threshold must be from 0 to 1; got \(threshold).") }
        }
    }

    func request() throws -> ScreenshotRequest {
        ScreenshotRequest(
            scale: try scale.map(ScreenshotScale.parse) ?? .native,
            region: try region.map(PointRegion.parse),
            format: try ScreenCapture.resolveFormat(named: format, quality: quality, outputPath: output)
        )
    }

    func run() async throws {
        let request = try request()
        let logger = OffsiderLogger()
        let route = try await DeviceRouter.route(deviceOption.id, logger: logger)
        let report = try await take(request, on: route)

        guard let comparison = report.comparison else {
            if json {
                print(report.jsonLine())
            } else if let path = report.path {
                print(path)
            }
            return
        }
        if json {
            Self.writeError(comparison.summary)
            print(report.jsonLine())
        } else {
            print(comparison.summary)
        }
        if comparison.outcome == .unchanged {
            throw ExitCode(OffsiderExitCode.unverified.rawValue)
        }
    }

    /// Captures, writes the image when asked and compares; prints only the stderr notes.
    @MainActor
    func take(_ request: ScreenshotRequest, on route: DeviceRouter.Route) async throws -> ScreenshotReport {
        let backend = route.backend
        try await backend.prepare()
        let booted = try await backend.requireBootedDevice(route.device)

        let baseline = try compare.map(ScreenCapture.readBaseline)
        let capture: CapturedScreen
        if let selected = try await displayOption.resolve(on: backend, device: booted.id, deviceName: deviceOption.id) {
            guard let capturer = backend as? any DisplayCapturing else {
                throw CLIError(errorDescription: "--display is not available for \(deviceOption.id) yet. Omit it to capture the active display.")
            }
            capture = try await ScreenCapture.capture(capturer, device: booted.id, display: selected.display, posture: selected.list.posture)
        } else {
            capture = try await ScreenCapture.capture(backend, device: booted.id)
        }
        let rendered = try ScreenCapture.render(capture, request: request)

        var path: String?
        if compare == nil || output != nil {
            let prefix = route.device.platform == .android ? "Emulator Screenshot" : "Simulator Screenshot"
            let url = try ScreenCapture.outputURL(path: output, prefix: prefix, deviceName: booted.name, format: request.format)
            try rendered.encoded(as: request.format).write(to: url)
            path = url.path
            Self.writeError("Screenshot saved to \(url.path) (\(rendered.image.width) x \(rendered.image.height) px)")
        }

        guard let compare, let baseline else {
            return rendered.report(path: path, format: request.format, capture: capture)
        }

        if ScreenImage.isJPEG(baseline) {
            Self.writeError("Warning: JPEG baselines can read as changed because of compression artefacts; prefer PNG.")
        }
        let bands = await backend.volatileScreenBands(for: booted.id)
        let result = try ScreenCapture.compare(
            rendered, capture: capture, baseline: baseline, baselinePath: compare, bands: bands, threshold: threshold ?? 0
        )
        return rendered.report(path: path, format: path == nil ? nil : request.format, capture: capture, comparison: result)
    }

    private static func writeError(_ line: String) {
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }
}
