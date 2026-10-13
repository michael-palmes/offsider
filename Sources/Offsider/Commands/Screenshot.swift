import ArgumentParser
import Foundation
import OffsiderCore

extension ScreenCompare.Outcome: ExpressibleByArgument {}

struct Screenshot: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "screenshot",
        abstract: "Capture the device display as a PNG or JPEG, optionally cropped, scaled to points or compared with a baseline",
        discussion: """
        --scale points makes one image pixel one point, so image coordinates are tap coordinates. \
        --region takes points as describe-ui prints them; the crop happens before scaling. \
        --compare captures, applies the same --region and --scale, and exits 0 when more than \
        --threshold of the screen's tiles changed, or 5 when not; --expect unchanged turns that round, exiting 0 \
        only when nothing beyond the threshold changed. It also counts the changed pixels, and \
        --diff-output writes an image of where they are; an evidence run keeps a diff only when pixels changed. \
        --display captures one display of a foldable (see `offsider displays`); a display that is not active \
        is captured as it is, often dark. \
        --mask-secure (or OFFSIDER_MASK_SECURE=1) reads the accessibility tree first and paints every password field \
        opaque black before the image is written or compared; when a password field cannot be located, the image is \
        withheld and no file is written. --mask-id, --mask-label, --mask-label-contains, --mask-text and --mask-emails paint the elements \
        they match the same way, even on a screen beneath a page (counted in maskedBeneath); --mask-region paints a rectangle \
        in points before any --region crop and reads no tree. A selector that matches nothing is named in maskUnmatched \
        and on stderr, and the image is still written. \
        --mask-skip-beneath leaves those matches, and an evidence run's email and id masks, unpainted when their element is on \
        a screen beneath a page (counted in skippedBeneath); password fields and --mask-region are always painted, and with no \
        page found nothing is skipped. Use it only when the page on top is opaque: a translucent or animating page shows what is \
        beneath, so check the image. \
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

    @Option(name: .customLong("diff-output"), help: ArgumentHelp("With --compare, write a PNG of the capture faded to white with changed pixels in magenta to this file, or a directory for a generated name.", valueName: "png"))
    var diffOutput: String?

    @Option(help: ArgumentHelp("With --compare, the fraction of tiles that may change and still count as unchanged (0 to 1, default 0).", valueName: "0-1"))
    var threshold: Double?

    @Option(help: ArgumentHelp("With --compare, the outcome that passes: changed (the default) or unchanged. Exit 5 when the capture does not match it.", valueName: "changed|unchanged"))
    var expect: ScreenCompare.Outcome?

    @Flag(name: .customLong("mask-secure"), help: "Paint password fields black before writing the image; withhold it when one cannot be located. OFFSIDER_MASK_SECURE=1 turns this on by default.")
    var maskSecure = false

    @Option(name: .customLong("mask-id"), parsing: .upToNextOption, help: ArgumentHelp("Paint every element with this id black. Repeatable.", valueName: "id"))
    var maskIDs: [String] = []

    @Option(name: .customLong("mask-label"), parsing: .upToNextOption, help: ArgumentHelp("Paint every element with this label black, matched as --label matches. Repeatable.", valueName: "text"))
    var maskLabels: [String] = []

    @Option(name: .customLong("mask-label-contains"), parsing: .upToNextOption, help: ArgumentHelp("Paint every element whose label holds this text black, matched as --label-contains matches. Repeatable.", valueName: "text"))
    var maskLabelsContaining: [String] = []

    @Option(name: .customLong("mask-text"), parsing: .upToNextOption, help: ArgumentHelp("Paint the innermost elements whose label, value, title, text, content description or hint matches this case-insensitive regular expression black. Repeatable.", valueName: "regex"))
    var maskTexts: [String] = []

    @Flag(name: .customLong("mask-emails"), help: "Paint the innermost elements showing an email address black.")
    var maskEmails = false

    @Option(name: .customLong("mask-region"), parsing: .upToNextOption, help: ArgumentHelp("Paint this rectangle, in points, black before any --region crop; reads no tree. Repeatable.", valueName: "x,y,w,h"))
    var maskRegions: [String] = []

    @Flag(name: .customLong("mask-skip-beneath"), help: "Leave matches of the other masks and the run's email and id masks unpainted on a screen beneath a page. Password fields and --mask-region are always painted.")
    var maskSkipBeneath = false

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
        if let diffOutput {
            guard compare != nil else { throw ValidationError("--diff-output applies to --compare only.") }
            let pathExtension = (diffOutput as NSString).pathExtension.lowercased()
            guard pathExtension != "jpg", pathExtension != "jpeg" else {
                throw ValidationError("--diff-output writes a PNG; use a .png path or a directory.")
            }
        }
        if expect != nil, compare == nil {
            throw ValidationError("--expect applies to --compare only.")
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
            labelsContaining: maskLabelsContaining,
            texts: maskTexts,
            emails: maskEmails,
            regions: try maskRegions.map { try PointRegion.parse($0, option: "--mask-region") },
            skipsBeneath: maskSkipBeneath
        )
    }

    func run() async throws {
        let request = try request()
        let logger = OffsiderLogger()
        let route = try await DeviceRouter.route(deviceOption.id, logger: logger)
        let report = try await take(request, on: route, masks: masksWithRunDefaults(try maskPlan()), plain: !json)

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
        if !comparison.met {
            throw ExitCode(OffsiderExitCode.unverified.rawValue)
        }
    }

    /// Standalone: a tree mask reads one fresh tree; without one, no tree is read. `plain` allows writing the device's PNG as it came.
    @MainActor
    func take(_ request: ScreenshotRequest, on route: DeviceRouter.Route, masks: MaskPlan, plain: Bool = false) async throws -> ScreenshotReport {
        try await take(request, on: route, masks: masks, plain: plain) { try await route.backend.accessibilityTree(for: route.device) }
    }

    /// An Android PNG at native scale with nothing to crop, paint or compare is written as the device sent it, sized from its header, with no screen read.
    func isPlain(_ request: ScreenshotRequest, masks: MaskPlan, platform: DevicePlatform) -> Bool {
        platform == .android && request.format == .png && request.scale == .native && request.region == nil
            && masks.isEmpty && compare == nil && displayOption.id == nil
    }

    /// Captures, paints `masks` (reading the tree from `tree` only when a mask needs it), writes the image when asked and compares; prints only the stderr notes.
    @MainActor
    func take(
        _ request: ScreenshotRequest,
        on route: DeviceRouter.Route,
        masks: MaskPlan,
        plain: Bool = false,
        tree treeSource: @MainActor () async throws -> UITree
    ) async throws -> ScreenshotReport {
        let backend = route.backend
        try await backend.prepare()
        let booted = try await backend.requireBootedDevice(route.device)
        let recorder = EvidenceRecorder.current
        let token = try recorder.begin(device: booted.id, kind: "screenshot")

        var devicePNG: Data?
        if plain, isPlain(request, masks: masks, platform: route.device.platform) {
            let png = try await backend.screenshotPNG(for: booted.id)
            if let size = PNGHeader.size(of: png) {
                return try writePlain(png, size: size, booted: booted, platform: route.device.platform, token: token, recorder: recorder)
            }
            devicePNG = png
        }

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
        if let devicePNG {
            capture = try ScreenCapture.make(png: devicePNG, platform: route.device.platform, screen: try? await backend.screenInfo(for: booted.id))
        } else if let selected {
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
            let skipped = result.skipped?.values.reduce(0, +) ?? 0
            if skipped > 0 {
                Self.writeError("Note: --mask-skip-beneath left \(skipped == 1 ? "1 match" : "\(skipped) matches") on a screen beneath a page unpainted (skippedBeneath).")
            }
            let beneath = result.beneath.values.reduce(0, +)
            if beneath > 0 {
                let skippable = !masks.skipsBeneath && result.beneath.keys.contains(where: \.skippableBeneath)
                let advice = skippable ? "; --mask-skip-beneath leaves them unpainted" : ""
                Self.writeError("Note: \(beneath == 1 ? "1 mask was" : "\(beneath) masks were") painted for elements on a screen beneath a page, so black boxes can sit over the page on top (maskedBeneath)\(advice).")
            }
        }
        let rendered = try ScreenCapture.render(capture, request: request)

        var path: String?
        if output != nil || (compare == nil && token == nil) {
            let prefix = route.device.platform == .android ? "Emulator Screenshot" : "Simulator Screenshot"
            let url = try ScreenCapture.outputURL(path: output, prefix: prefix, deviceName: booted.name, format: request.format)
            try rendered.encoded(as: request.format).write(to: url)
            path = url.path
            Self.writeError("Screenshot saved to \(url.path) (\(rendered.image.width) x \(rendered.image.height) px)")
        }
        var runFile: String?
        if let token {
            runFile = try Self.writeRunCopy(try rendered.encoded(as: request.format), format: request.format, token: token, recorder: recorder, otherCopy: path)
            recorder.update(token) { entry in
                entry.output = path
                entry.masked = masked.map { $0.painted.values.reduce(0, +) }
                entry.skippedBeneath = masked?.skipped.map { $0.values.reduce(0, +) }
            }
            if path == nil, let runFile {
                path = runFile
                Self.writeError("Screenshot saved to \(runFile) (\(rendered.image.width) x \(rendered.image.height) px)")
            }
        }

        guard let compare, let baseline else {
            var report = rendered.report(path: path, format: request.format, capture: capture, masks: masked)
            report.runFile = runFile
            return report
        }

        if ScreenImage.isJPEG(baseline) {
            Self.writeError("Warning: JPEG baselines can read as changed because of compression artefacts; prefer PNG.")
        }
        let bands = await backend.volatileScreenBands(for: booted.id)
        var (result, diffImage) = try ScreenCapture.comparison(
            rendered, capture: capture, baseline: baseline, baselinePath: compare, bands: bands, threshold: threshold ?? 0
        )
        result.expected = expect ?? .changed
        var report = rendered.report(path: path, format: path == nil ? nil : request.format, capture: capture, comparison: result, masks: masked)
        report.runFile = runFile
        recorder.update(token) { entry in
            entry.changed = result.outcome == .changed
            entry.expect = result.expected.rawValue
        }
        if diffOutput != nil {
            let url = try ScreenCapture.outputURL(path: diffOutput, prefix: "Screenshot Diff", deviceName: booted.name, format: .png)
            try ScreenImage.encode(diffImage, as: .png).write(to: url)
            report.diffPath = url.path
            Self.writeError("Diff saved to \(url.path)")
        }
        if let token, runFile != nil, (result.pixels?.changedPixels ?? 0) > 0, let diffPath = try recorder.diffPath(token) {
            do {
                try RunFolder.writeNew(ScreenImage.encode(diffImage, as: .png), toPath: diffPath)
            } catch {
                recorder.update(token) { $0.diff = nil }
                Self.writeError("Warning: could not write the run's diff to \(diffPath): \(error.localizedDescription)")
            }
        }
        return report
    }

    /// Writes the device's PNG unchanged to `--output` or the default name, and into any run; the report carries only its path and size.
    @MainActor
    private func writePlain(
        _ png: Data, size: (width: Int, height: Int), booted: BootedDevice, platform: DevicePlatform,
        token: EvidenceRecorder.Token?, recorder: EvidenceRecorder
    ) throws -> ScreenshotReport {
        var path: String?
        if output != nil || token == nil {
            let prefix = platform == .android ? "Emulator Screenshot" : "Simulator Screenshot"
            let url = try ScreenCapture.outputURL(path: output, prefix: prefix, deviceName: booted.name, format: .png)
            try png.write(to: url)
            path = url.path
            Self.writeError("Screenshot saved to \(url.path) (\(size.width) x \(size.height) px)")
        }
        var runFile: String?
        if let token {
            runFile = try Self.writeRunCopy(png, format: .png, token: token, recorder: recorder, otherCopy: path)
            recorder.update(token) { $0.output = path }
            if path == nil, let runFile {
                path = runFile
                Self.writeError("Screenshot saved to \(runFile) (\(size.width) x \(size.height) px)")
            }
        }
        var report = ScreenshotReport(path: path, width: size.width, height: size.height, pixelsPerPoint: nil, region: nil, orientation: nil, upright: true, format: .png)
        report.runFile = runFile
        return report
    }

    /// The run's copy; when it is the only copy and cannot be written, the command fails with `run_unavailable`.
    @MainActor
    private static func writeRunCopy(_ encoded: Data, format: ImageFormat, token: EvidenceRecorder.Token, recorder: EvidenceRecorder, otherCopy: String?) throws -> String? {
        do {
            let runPath = try recorder.reserveFile(token, extension: format.fileExtension)
            try RunFolder.writeNew(encoded, toPath: runPath)
            return runPath
        } catch {
            recorder.update(token) { $0.file = nil }
            let message = "Could not write the screenshot into the run: \(OffsiderCommand.message(for: error))"
            guard otherCopy != nil else {
                throw CLIError(errorDescription: message + ". Fix the run folder, or stop the run with `offsider run stop`.", reason: .runUnavailable, hint: "offsider run status")
            }
            writeError("Warning: \(message); the --output copy was written.")
            return nil
        }
    }

    /// The capture's own masks with the run's added, so a capture never drops a run mask; only --mask-skip-beneath leaves one unpainted beneath a page.
    @MainActor
    func masksWithRunDefaults(_ own: MaskPlan) -> MaskPlan {
        guard let defaults = EvidenceRecorder.current.defaultMasks else { return own }
        return own.union(defaults)
    }

    private static func writeError(_ line: String) {
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }
}
