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
        Password fields are masked by default: the accessibility tree is read first and every password field is painted \
        opaque black before the image is written or compared; when a password field cannot be located, the image is \
        withheld and no file is written. --no-mask-secure (or OFFSIDER_MASK_SECURE=0) skips the tree read and the mask, \
        except during an evidence run that masks them. --mask-id, --mask-label, --mask-label-contains, --mask-text and --mask-emails paint the elements \
        they match the same way, even on a screen beneath a page (counted in maskedBeneath); --mask-region paints a rectangle \
        in points before any --region crop and reads no tree. A selector that matches nothing is named in maskUnmatched \
        and on stderr, and the image is still written. \
        --mask-skip-beneath leaves those matches, and an evidence run's email and id masks, unpainted when their element is on \
        a screen beneath a page (counted in skippedBeneath); password fields and --mask-region are always painted, and with no \
        page found nothing is skipped. Use it only when the page on top is opaque: a translucent or animating page shows what is \
        beneath, so check the image. \
        Masks cover what the tree describes: web views, canvases, images and text drawn after the tree read can \
        still show. Video is never masked: record-video and stream-video refuse while a password field is on screen.
        """
    )

    @OptionGroup
    var deviceOption: DeviceOption

    @OptionGroup
    var appOption: AppOption

    @OptionGroup
    var displayOption: DisplayOption

    @Option(help: "Output file path, or a directory for a generated name. Defaults to 'Simulator Screenshot - <device name> - <timestamp>.png' (iOS simulator), 'Emulator Screenshot - <AVD> - <timestamp>.png' (Android emulator) or 'Screenshot - <device name> - <timestamp>.png' (iPhone, iPad or Android phone) in the current directory. With --compare, an image is written only when this is given.")
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

    @Flag(name: .customLong("mask-secure"), inversion: .prefixedNo, help: "Paint password fields black before writing the image, and withhold it when one cannot be located (the default; OFFSIDER_MASK_SECURE=0 turns it off).")
    var maskSecure: Bool?

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

    /// The capture's flag, else the batch's, else `OFFSIDER_MASK_SECURE`, else on.
    static func masksSecure(flag: Bool?, batchDefault: Bool? = nil, environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        flag ?? batchDefault ?? EnvironmentFlag.bool("OFFSIDER_MASK_SECURE", in: environment) ?? true
    }

    func validate() throws {
        do {
            _ = try request()
        } catch let error as UserFacingError {
            throw ValidationError(error.userFacingDescription)
        }
        do {
            _ = try maskPlan(gated: false)
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

    /// The masks the flags ask for; `batchDefault` is `batch --mask-secure` or `--no-mask-secure`, which a step's own flag beats.
    /// When `gated`, password masking turned off is refused for an agent until a person confirmed it in this process.
    func maskPlan(batchDefault: Bool? = nil, environment: [String: String] = ProcessInfo.processInfo.environment, gated: Bool = true) throws -> MaskPlan {
        for pattern in maskTexts {
            _ = try MaskPlan.compile(pattern)
        }
        let secure = Self.masksSecure(flag: maskSecure, batchDefault: batchDefault, environment: environment)
        if gated, !secure { try UnmaskedConsent.require() }
        return MaskPlan(
            secure: secure,
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
        if try !maskPlan(gated: false).secure { try await UnmaskedConsent.confirm(command: "screenshot") }
        let logger = OffsiderLogger()
        let watchdog = DeviceWatchdog()
        let route = try await DeviceRouter.routeForInput(deviceOption.id, logger: logger, watchdog: watchdog, locking: false)
        await appOption.apply(to: route)
        let console = Console.current
        let masks = try await masksWithRunDefaults(maskPlan())
        try await watchdog.guardingSetup(device: deviceOption.id) { try await route.backend.prepare() }
        let report = try await console.progress("Capturing the screen") {
            // The bound also covers a --wait-lock wait, since an Android mask's tree read takes the device's lock.
            try await watchdog.guardingRead(of: route.device, extra: DeviceClaims.current.longestWait) {
                try await take(request, on: route, masks: masks, plain: !json)
            }
        }

        guard let comparison = report.comparison else {
            if json {
                console.data(report.jsonLine() + "\n")
            } else if let path = report.path {
                console.show(ReadPersonView.screenshot(report, path: path))
            }
            return
        }
        if json {
            console.data(comparison.summary + "\n", to: .err)
            console.data(report.jsonLine() + "\n")
        } else {
            console.show(ReadPersonView.comparison(report, comparison))
        }
        if !comparison.met {
            throw ExitCode(OffsiderExitCode.unverified.rawValue)
        }
    }

    /// Standalone: a tree mask reads one fresh tree; without one, no tree is read. `plain` allows writing the device's PNG as it came.
    @MainActor
    func take(_ request: ScreenshotRequest, on route: DeviceRouter.Route, masks: MaskPlan, plain: Bool = false) async throws -> ScreenshotReport {
        var report = try await take(request, on: route, masks: masks, plain: plain) {
            guard let reader = route.backend as? any MaskTreeReading else { return try await route.backend.accessibilityTree(for: route.device) }
            return try await reader.maskTree(for: route.device)
        }
        report.captureSource = (route.backend as? any CaptureSourceReporting)?.captureSource(for: route.device)
        return report
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
        masks requested: MaskPlan,
        plain: Bool = false,
        tree treeSource: @MainActor () async throws -> UITree
    ) async throws -> ScreenshotReport {
        let backend = route.backend
        let own = requested
        let config = try MaskConfigs.current()?.config
        let masks = config.map { requested.union($0.plan) } ?? requested
        try await backend.prepare()
        let booted = try await backend.requireBootedDevice(route.device)
        let recorder = EvidenceRecorder.current
        let token = try recorder.begin(device: booted.id, kind: "screenshot")

        var devicePNG: Data?
        if plain, isPlain(request, masks: masks, platform: route.device.platform) {
            let png = try await backend.screenshotPNG(for: booted.id)
            if let size = PNGHeader.size(of: png) {
                return try writePlain(png, size: size, booted: booted, token: token, recorder: recorder)
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
        let revealed = tree != nil && masks.secure ? await TreeCache.revealedSecrets(for: booted.id, backend: backend) : nil
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
            var result = try Timings.measure("mask") { try ScreenCapture.masking(capture, plan: masks, tree: tree, revealed: revealed) }
            if let config {
                // The file's selectors are standing masks, so one that matches nothing on this screen is not worth a warning.
                let quiet = config.selectorNames.subtracting(Self.selectorNames(own))
                result.unmatched.removeAll(where: quiet.contains)
            }
            capture = result.capture
            masked = result
            let console = Console.current
            if result.unproven != nil {
                console.notice(.warning(
                    "Masks can't see behind this modal; check the image",
                    agent: "a modal window covers the app and Android leaves what is behind it out of the tree, so masks may miss text drawn there; check the image or add --mask-region (maskUnproven)."
                ))
            }
            if !result.unmatched.isEmpty {
                let names = result.unmatched.joined(separator: ", ")
                console.notice(.warning("Nothing matched \(names), so nothing was painted for it", agent: "nothing matched \(names), so nothing was painted for it."))
            }
            let skipped = result.skipped?.values.reduce(0, +) ?? 0
            if skipped > 0 {
                let matches = skipped == 1 ? "1 match" : "\(skipped) matches"
                console.notice(.note(
                    "Left \(matches) beneath a page unpainted",
                    agent: "--mask-skip-beneath left \(matches) on a screen beneath a page unpainted (skippedBeneath)."
                ))
            }
            let beneath = result.beneath.values.reduce(0, +)
            if beneath > 0 {
                let skippable = !masks.skipsBeneath && result.beneath.keys.contains(where: \.skippableBeneath)
                let advice = skippable ? "; --mask-skip-beneath leaves them unpainted" : ""
                let painted = beneath == 1 ? "1 mask was" : "\(beneath) masks were"
                console.notice(.note(
                    "\(painted) painted beneath a page, so black boxes can cover the page on top\(advice)",
                    agent: "\(painted) painted for elements on a screen beneath a page, so black boxes can sit over the page on top (maskedBeneath)\(advice)."
                ))
            }
        }
        let rendered = try ScreenCapture.render(capture, request: request)

        var path: String?
        if output != nil || (compare == nil && token == nil) {
            let target = try ScreenCapture.outputURL(path: output, prefix: ScreenCapture.defaultPrefix(for: booted.id), deviceName: booted.name, format: request.format)
            let url = try ScreenCapture.write(try rendered.encoded(as: request.format), to: target)
            path = url.path
            Self.saved(url.path, width: rendered.image.width, height: rendered.image.height)
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
                Self.saved(runFile, width: rendered.image.width, height: rendered.image.height)
            }
        }

        guard let compare, let baseline else {
            var report = rendered.report(path: path, format: request.format, capture: capture, masks: masked)
            report.runFile = runFile
            return report
        }

        if ScreenImage.isJPEG(baseline) {
            Console.current.notice(.warning(
                "A JPEG baseline can read as changed; prefer PNG", agent: "JPEG baselines can read as changed because of compression artefacts; prefer PNG."
            ))
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
            let target = try ScreenCapture.outputURL(path: diffOutput, prefix: "Screenshot Diff", deviceName: booted.name, format: .png)
            let url = try ScreenCapture.write(try ScreenImage.encode(diffImage, as: .png), to: target)
            report.diffPath = url.path
            ReadPersonView.saved("Diff saved to \(url.path)", person: "Diff saved to \(TerminalText.homePath(url.path))")
        }
        if let token, runFile != nil, (result.pixels?.changedPixels ?? 0) > 0, let diffPath = try recorder.diffPath(token) {
            do {
                try RunFolder.writeNew(ScreenImage.encode(diffImage, as: .png), toPath: diffPath)
            } catch {
                recorder.update(token) { $0.diff = nil }
                let reason = TerminalText.line(error.localizedDescription)
                Console.current.notice(.warning(
                    "Could not write the run's diff to \(TerminalText.homePath(diffPath)): \(reason)", agent: "could not write the run's diff to \(diffPath): \(reason)"
                ))
            }
        }
        return report
    }

    /// Writes the device's PNG unchanged to `--output` or the default name, and into any run; the report carries only its path and size.
    @MainActor
    private func writePlain(
        _ png: Data, size: (width: Int, height: Int), booted: BootedDevice,
        token: EvidenceRecorder.Token?, recorder: EvidenceRecorder
    ) throws -> ScreenshotReport {
        var path: String?
        if output != nil || token == nil {
            let target = try ScreenCapture.outputURL(path: output, prefix: ScreenCapture.defaultPrefix(for: booted.id), deviceName: booted.name, format: .png)
            let url = try ScreenCapture.write(png, to: target)
            path = url.path
            Self.saved(url.path, width: size.width, height: size.height)
        }
        var runFile: String?
        if let token {
            runFile = try Self.writeRunCopy(png, format: .png, token: token, recorder: recorder, otherCopy: path)
            recorder.update(token) { $0.output = path }
            if path == nil, let runFile {
                path = runFile
                Self.saved(runFile, width: size.width, height: size.height)
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
            let shown = TerminalText.line(message, cap: TerminalText.maxErrorCharacters)
            Console.current.notice(.warning("\(shown); the --output copy was written", agent: "\(shown); the --output copy was written."))
            return nil
        }
    }

    /// The capture's own masks with the run's added, so a capture never drops a run mask; only --mask-skip-beneath leaves one unpainted beneath a page.
    @MainActor
    func masksWithRunDefaults(_ own: MaskPlan) -> MaskPlan {
        guard let defaults = EvidenceRecorder.current.defaultMasks else { return own }
        return own.union(defaults)
    }

    /// `--mask-id x` and the like, as `MaskResult.unmatched` names them.
    static func selectorNames(_ plan: MaskPlan) -> Set<String> {
        MaskConfig(ids: plan.ids, labels: plan.labels, labelContains: plan.labelsContaining, valuePatterns: plan.texts).selectorNames
    }

    /// `Screenshot saved to <path> (W x H px)` on stderr for an agent; a person reads the receipt.
    private static func saved(_ path: String, width: Int, height: Int) {
        let size = "\(width) x \(height) px"
        ReadPersonView.saved("Screenshot saved to \(path) (\(size))", person: "Screenshot saved to \(TerminalText.homePath(path)) · \(size)")
    }
}

/// `--no-mask-secure` and `OFFSIDER_MASK_SECURE=0` show password fields, so for an agent a person confirms them first.
enum UnmaskedConsent {
    nonisolated(unsafe) static var confirmed = false

    static let refusal = "Password fields stay masked when an agent runs this. Nothing was captured. "
        + "Run it from your own terminal, or keep the mask and hide other fields with --mask-id."

    /// Refuses for an agent unless a person confirmed in this process; a person at a terminal is never asked.
    static func require(profile: OutputProfile = .current) throws {
        guard profile == .agent, !confirmed else { return }
        throw CLIError.personRequired(refusal)
    }

    /// For an agent: a terminal on standard input, then Touch ID or the password; refused without either.
    static func confirm(command: String, profile: OutputProfile = .current) async throws {
        guard profile == .agent, !confirmed else { return }
        guard PersonPresence.terminal() else { throw CLIError.personRequired(refusal) }
        try await PersonPresence.confirm(reason: "\(command) with password fields unmasked")
        confirmed = true
    }
}
