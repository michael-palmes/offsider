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
        is captured as it is, often dark. \
        --mask-secure (or OFFSIDER_MASK_SECURE=1) reads the accessibility tree first and paints every password field \
        opaque black before the image is written or compared; when a password field cannot be located, the image is \
        withheld and no file is written. --mask-id, --mask-label, --mask-text and --mask-emails paint the elements \
        they match the same way; --mask-region paints a rectangle in points before any --region crop and reads no \
        tree. A selector that matches nothing is named in maskUnmatched and on stderr, and the image is still written. \
        Masks cover what the tree describes: web views, canvases, images and text drawn after the tree read can \
        still show. Video is never masked.
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

    @Flag(name: .customLong("mask-secure"), help: "Paint password fields black before writing the image; withhold it when one cannot be located. OFFSIDER_MASK_SECURE=1 turns this on by default.")
    var maskSecure = false

    @Option(name: .customLong("mask-id"), parsing: .upToNextOption, help: ArgumentHelp("Paint every element with this id black. Repeatable.", valueName: "id"))
    var maskIDs: [String] = []

    @Option(name: .customLong("mask-label"), parsing: .upToNextOption, help: ArgumentHelp("Paint every element with this label black, matched as --label matches. Repeatable.", valueName: "text"))
    var maskLabels: [String] = []

    @Option(name: .customLong("mask-text"), parsing: .upToNextOption, help: ArgumentHelp("Paint the innermost elements whose label, value, title, text, content description or hint matches this case-insensitive regular expression black. Repeatable.", valueName: "regex"))
    var maskTexts: [String] = []

    @Flag(name: .customLong("mask-emails"), help: "Paint the innermost elements showing an email address black.")
    var maskEmails = false

    @Option(name: .customLong("mask-region"), parsing: .upToNextOption, help: ArgumentHelp("Paint this rectangle, in points, black before any --region crop; reads no tree. Repeatable.", valueName: "x,y,w,h"))
    var maskRegions: [String] = []

    @Flag(name: .customLong("json"), help: "Print one JSON object to stdout; human text goes to stderr.")
    var json = false

    /// The flag, or `OFFSIDER_MASK_SECURE=1`.
    static func masksSecure(flag: Bool, environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        flag || environment["OFFSIDER_MASK_SECURE"] == "1"
    }

    func validate() throws {
        do {
            _ = try request()
        } catch let error as UserFacingError {
            throw ValidationError(error.userFacingDescription)
        }
        do {
            _ = try maskPlan()
        } catch let error as MaskPatternError {
            throw ValidationError(error.description)
        } catch let error as ScreenRegionError {
            throw ValidationError(error.message)
        }
        if let threshold {
            guard compare != nil else { throw ValidationError("--threshold applies to --compare only.") }
            guard (0...1).contains(threshold) else { throw ValidationError("--threshold must be from 0 to 1; got \(threshold).") }
        }
    }

    func request() throws -> ScreenshotRequest {
        ScreenshotRequest(
            scale: try scale.map(ScreenshotScale.parse) ?? .native,
            region: try region.map { try PointRegion.parse($0) },
            format: try ScreenCapture.resolveFormat(named: format, quality: quality, outputPath: output)
        )
    }

    /// The masks the flags ask for; `secureByDefault` adds `--mask-secure`, as `batch --mask-secure` does.
    func maskPlan(secureByDefault: Bool = false, environment: [String: String] = ProcessInfo.processInfo.environment) throws -> MaskPlan {
        for pattern in maskTexts {
            _ = try MaskPlan.compile(pattern)
        }
        return MaskPlan(
            secure: Self.masksSecure(flag: maskSecure || secureByDefault, environment: environment),
            ids: maskIDs,
            labels: maskLabels,
            texts: maskTexts,
            emails: maskEmails,
            regions: try maskRegions.map { try PointRegion.parse($0, option: "--mask-region") }
        )
    }

    func run() async throws {
        let request = try request()
        let logger = OffsiderLogger()
        let route = try await DeviceRouter.route(deviceOption.id, logger: logger)
        let report = try await take(request, on: route, masks: try maskPlan())

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

    /// Standalone: a tree mask reads one fresh tree; without one, no tree is read.
    @MainActor
    func take(_ request: ScreenshotRequest, on route: DeviceRouter.Route, masks: MaskPlan) async throws -> ScreenshotReport {
        try await take(request, on: route, masks: masks) { try await route.backend.accessibilityTree(for: route.device) }
    }

    /// Captures, paints `masks` (reading the tree from `tree` only when a mask needs it), writes the image when asked and compares; prints only the stderr notes.
    @MainActor
    func take(
        _ request: ScreenshotRequest,
        on route: DeviceRouter.Route,
        masks: MaskPlan,
        tree treeSource: @MainActor () async throws -> UITree
    ) async throws -> ScreenshotReport {
        let backend = route.backend
        try await backend.prepare()
        let booted = try await backend.requireBootedDevice(route.device)

        let baseline = try compare.map(ScreenCapture.readBaseline)
        let selected = try await displayOption.resolve(on: backend, device: booted.id, deviceName: deviceOption.id)
        var tree: UITree?
        if masks.needsTree {
            if let selected, !selected.display.active {
                throw MaskUnproven(detail: "The \(selected.display.descriptor.screenDisplay.id) display is not active and the accessibility tree describes the active display only")
            }
            // Read before the capture, so the frames describe the screen the pixels show.
            tree = try await Timings.measure("accessibility") { try await treeSource() }
        }
        var capture: CapturedScreen
        if let selected {
            guard let capturer = backend as? any DisplayCapturing else {
                throw CLIError(errorDescription: "--display is not available for \(deviceOption.id) yet. Omit it to capture the active display.", reason: .notSupported)
            }
            capture = try await ScreenCapture.capture(capturer, device: booted.id, display: selected.display, posture: selected.list.posture)
        } else {
            capture = try await ScreenCapture.capture(backend, device: booted.id)
        }
        var masked: ScreenCapture.MaskResult?
        if !masks.isEmpty {
            let result = try Timings.measure("mask") { try ScreenCapture.masking(capture, plan: masks, tree: tree) }
            capture = result.capture
            masked = result
            if !result.unmatched.isEmpty {
                Self.writeError("Warning: nothing matched \(result.unmatched.joined(separator: ", ")), so nothing was painted for it.")
            }
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
            return rendered.report(path: path, format: request.format, capture: capture, masks: masked)
        }

        if ScreenImage.isJPEG(baseline) {
            Self.writeError("Warning: JPEG baselines can read as changed because of compression artefacts; prefer PNG.")
        }
        let bands = await backend.volatileScreenBands(for: booted.id)
        let result = try ScreenCapture.compare(
            rendered, capture: capture, baseline: baseline, baselinePath: compare, bands: bands, threshold: threshold ?? 0
        )
        return rendered.report(path: path, format: path == nil ? nil : request.format, capture: capture, comparison: result, masks: masked)
    }

    private static func writeError(_ line: String) {
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }
}
