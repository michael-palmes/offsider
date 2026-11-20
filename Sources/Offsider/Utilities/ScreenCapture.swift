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
            maskedBeneath: masks?.beneath ?? [:],
            skippedBeneath: masks?.skipped,
            maskUnmatched: masks?.unmatched ?? [],
            maskUnproven: masks?.unproven
        )
    }
}

@MainActor
enum ScreenCapture {
    static func capture(_ backend: any DeviceBackend, device: DeviceID) async throws -> CapturedScreen {
        (backend as? any ScreenStatusPrefetching)?.prefetchScreenStatus(for: device)
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

    /// What masking painted: rectangles per kind asked for, those on a screen beneath a page, the matches left unpainted there, and the selectors that matched nothing.
    struct MaskResult {
        let capture: CapturedScreen
        let painted: [MaskKind: Int]
        var beneath: [MaskKind: Int] = [:]
        /// Nil unless `--mask-skip-beneath` was given; then every skippable kind asked for, zeros included.
        var skipped: [MaskKind: Int]?
        var unmatched: [String]
        /// `remembered` (painted where the tree cache last saw it), `modal` (an Android modal window, an iOS backdrop over drawn text, or no cache under an iOS modal) or `keyboard` (an unlisted iOS keyboard bar).
        var unproven: String? = nil
        /// What was painted where the tree cache last saw it (`--mask-id profile-email`, `an email address`).
        var remembered: [String] = []
        /// Email addresses the text read found that no listed element holds.
        var unlistedEmails = 0
    }

    /// Why this tree cannot prove its masks: `truncated` by the device; on Android, `no-windows` when uiautomator lists none, or `modal` when a window, but an empty or opaque LogBox one, hides those beneath.
    nonisolated static func unproven(_ tree: UITree) -> String? {
        if tree.sourceTruncated { return "truncated" }
        guard tree.platform == .android else { return nil }
        guard let windows = tree.windows else { return "no-windows" }
        // Android lists no window beneath a touch-modal system window, so the app's password fields can show with no tree to find them.
        if tree.systemWindow != nil, !windows.contains(where: { $0.kind == "application" }) { return "modal" }
        let context = UITreeContext(tree: tree)
        guard let window = context.window, window.kind == .modal, !window.empty, context.logBox?.inspector != true else { return nil }
        return "modal"
    }

    /// The warning for `unproven`'s reason; `subject` is what to check, such as `the image`.
    nonisolated static func unprovenNotice(_ reason: String, subject: String) -> Notice {
        switch reason {
        case "truncated":
            return .warning(
                "The screen was not read whole; check \(subject)",
                agent: "the device cut this accessibility tree short, so masks may miss elements past the cut; check \(subject) or add --mask-region (maskUnproven)."
            )
        case "no-windows":
            return .warning(
                "Masks can't tell if a modal is open; check \(subject)",
                agent: "this read lists no windows, so a modal hiding what is behind it cannot be told and masks may miss text drawn there; check \(subject) or add --mask-region (maskUnproven)."
            )
        case "remembered":
            return rememberedNotice([], subject: subject)
        case "keyboard":
            return .warning(
                "Painted a band for the keyboard's suggestions; check \(subject)",
                agent: "a keyboard is up and its suggestion bar is not in the tree, so a band was painted where one would be; check \(subject), or close the keyboard first with `offsider keyboard hide` (maskUnproven)."
            )
        default:
            return .warning(
                "Masks can't see behind this modal; check \(subject)",
                agent: "a modal covers the app and leaves what is behind it out of the tree, so masks may miss text drawn there; check \(subject) or add --mask-region (maskUnproven)."
            )
        }
    }

    /// Painted where the tree cache last saw what `names` names, as an iOS modal hides it from the tree now.
    nonisolated static func rememberedNotice(_ names: [String], subject: String) -> Notice {
        let named = names.isEmpty ? "a masked element" : names.joined(separator: ", ")
        return .warning(
            "Painted where the modal hides \(TerminalText.line(named, cap: 80)); check \(subject)",
            agent: "a modal hides \(named) from the tree, so its mask was painted where the tree cache last saw it, which no read proves; check \(subject) or add --mask-region (maskUnproven)."
        )
    }

    /// The text read found email addresses that no element the tree lists holds, painted all the same.
    nonisolated static func unlistedEmailNotice(_ count: Int, subject: String) -> Notice {
        let found = count == 1 ? "An email address shows" : "\(count) email addresses show"
        return .warning(
            "\(found) that the tree does not list; check \(subject)",
            agent: "\(found.prefix(1).lowercased() + found.dropFirst()) behind a modal that no element in the tree holds; it was painted from a text read, which may miss part of it; check \(subject) or add --mask-region (maskUnproven)."
        )
    }

    /// What text recognition found where an iOS backdrop hides the screen from every read: the lines no element lists, or `unread` when it could not finish.
    struct HiddenText {
        var lines: [ScreenTextLine] = []
        var unread = false
        /// False for a modal told by memory alone whose read saw nothing of the screen gone: a new screen, not a modal, so its own unlisted text proves nothing.
        var modalShown = true
        var unproven: Bool { unread || (modalShown && !lines.isEmpty) }
    }

    /// Recognition on the Mac is bounded, as a stalled read must not hold a capture; the fast pass, as the accurate one compiles its model for each new build.
    nonisolated static let hiddenTextLimit: TimeInterval = 2

    /// An iOS modal hiding the screen beneath, the cache's last tree of that screen and what the plan's masks name in it; `cacheOff` when none can be kept.
    struct BehindModal {
        let modal: ModalScreen
        let remembered: UITree?
        var found = RememberedMasks.Found()
        let cacheOff: Bool
    }

    /// Tree checks only, plus the device's tree cache file when a backdrop could hide a screen and a mask names elements or text; nil with no modal, at no cost.
    @MainActor
    static func behindModal(
        _ tree: UITree?, plan: MaskPlan, screen: UIScreenInfo?, device: DeviceID, backend: any DeviceBackend, environment: TreeCacheEnvironment = .current
    ) async -> BehindModal? {
        let statusBar = IOSBackend.statusBarHeight
        guard let tree, HiddenScreen.mayHide(tree, belowStatusBar: statusBar) else { return nil }
        var remembered: UITree?
        if environment.cacheOn, plan.recalls {
            let record = await TreeCache.load(for: device, backend: backend, environment: environment)
            remembered = RememberedMasks.tree(in: record, current: tree, screen: screen, now: environment.now(), statusBar: statusBar)
        }
        guard let modal = HiddenScreen.modal(in: tree, belowStatusBar: statusBar, remembered: remembered) else { return nil }
        var behind = BehindModal(modal: modal, remembered: remembered, cacheOff: !environment.cacheOn && plan.recalls)
        if let remembered {
            let selected = selectors(of: plan).map { kind, query in
                (kind: kind, name: selectorName(query), nodes: AccessibilityTargetResolver.candidates(roots: remembered.roots, query: query, elementType: nil, masks: nil).matches)
            }
            behind.found = (try? RememberedMasks.targets(plan: plan, selected: selected, remembered: remembered, current: tree, region: modal.region)) ?? RememberedMasks.Found()
        }
        // Told by memory alone, as a new screen is too: worth a text read only when the screen gone held something a mask names.
        if modal.byMemory, behind.found.isEmpty { return nil }
        return behind
    }

    /// Reads the capture's text only under an iOS modal hiding the screen beneath: for an email or text mask, a memory to confirm, or the band shape.
    nonisolated static func hiddenText(in capture: CapturedScreen, behind: BehindModal?, tree: UITree?, plan: MaskPlan) async -> HiddenText? {
        guard let tree, let behind, behind.modal.hidesBand || behind.modal.byMemory || plan.emails || !plan.texts.isEmpty else { return nil }
        let modal = behind.modal
        let region = modal.region
        guard capture.upright, let pixelsPerPoint = capture.pixelsPerPoint else { return HiddenText(unread: true) }
        let image = capture.image
        let lines = try? await Timings.measure("hidden-text") {
            try await DoctorProbes.withTimeout(hiddenTextLimit, operation: "Reading text behind a sheet") {
                await ScreenTextReader.framedLines(in: image, region: region, pixelsPerPoint: pixelsPerPoint)
            }
        }
        guard let read = lines else { return HiddenText(unread: true) }
        let unlisted = HiddenScreen.unlisted(read, in: tree)
        let shown = !modal.byMemory || behind.remembered.map { HiddenScreen.showsRemembered(unlisted, remembered: $0, current: tree) } == true
        return HiddenText(lines: unlisted, modalShown: shown)
    }

    /// What the tree cache remembers beneath an iOS modal for a plan's id, label, text and email masks.
    enum Remembered {
        case found(RememberedMasks.Found)
        /// The cache is off, so nothing beneath the modal can be remembered.
        case off
    }

    /// What the plan's masks name that the modal hides now; for a modal told by memory alone, only once the text read saw the old screen or could not finish.
    nonisolated static func remembered(_ behind: BehindModal?, hidden: HiddenText?) -> Remembered? {
        guard let behind else { return nil }
        if behind.cacheOff { return .off }
        guard !behind.found.isEmpty, !behind.modal.byMemory || hidden.map({ $0.unread || $0.modalShown }) == true else { return nil }
        return .found(behind.found)
    }

    nonisolated private static func selectors(of plan: MaskPlan) -> [(MaskKind, AccessibilityQuery)] {
        plan.ids.map { (MaskKind.id, AccessibilityQuery.id($0)) } + plan.labels.map { (MaskKind.label, AccessibilityQuery.label($0)) }
            + plan.labelsContaining.map { (MaskKind.labelContains, AccessibilityQuery.labelContains($0)) }
    }

    nonisolated private static func selectorName(_ query: AccessibilityQuery) -> String {
        "--mask-\(query.kind.dropFirst(2)) \(query.rawValue)"
    }

    /// Paints every mask in `plan` black; a capture that is not upright cannot be mapped, so it is withheld.
    /// `revealed` adds plain fields showing an earlier password field; `hidden` (text no read lists) and `remembered` (frames the cache saw beneath a modal) only add paint.
    nonisolated static func masking(
        _ capture: CapturedScreen, plan: MaskPlan, tree: UITree?, revealed: RevealedSecrets? = nil, hidden: HiddenText? = nil, remembered: Remembered? = nil
    ) throws -> MaskResult {
        var targets = MaskTargets()
        var hiddenNodes: [UINode] = []
        if let tree {
            // The standing masks hide some text: every element holding it is painted whole, and no rule's match may depend on it, so none tells whether a guess at it was right.
            var standing = AmbientMasks.outputMask()
            standing.revealed = plan.secure ? revealed : nil
            let hidden = plan.readsText || standing.revealed != nil ? MaskedFields.of(tree.roots, mask: standing) : nil
            // Password fields, shown or revealed, are painted as password fields; only what copies their text counts here.
            hiddenNodes = (hidden?.hiddenNodes(in: tree.roots) ?? []).filter { !$0.isSecure && standing.revealed?.matches($0) != true }
            let isHidden = { (node: UINode) in hiddenNodes.contains { $0.isSameElement(as: node) } }
            targets = try plan.textTargets(in: tree, hidden: isHidden)
            if plan.secure {
                targets.add(tree.roots.flatMap { $0.flattened() }.filter { $0.isSecure || revealed?.matches($0) == true }, as: .secure)
                // iOS paints its bar whole, below, so a suggestion that arrives after the read is covered too.
                if tree.platform != .ios { targets.add(KeyboardText.hiddenElements(in: tree.roots), as: .keyboard) }
            }
            for (kind, query) in selectors(of: plan) {
                let matches = AccessibilityTargetResolver.candidates(roots: tree.roots, query: query, elementType: nil, masks: standing).matches
                targets.add(matches, as: kind)
                if matches.isEmpty {
                    targets.unmatched.append(selectorName(query))
                }
            }
            targets.add(hiddenNodes, as: .rules)
            targets.foldIntoRules()
        }
        targets.frames[.region] = plan.regions.map { UIFrame(x: $0.x, y: $0.y, width: $0.width, height: $0.height) }
        let placement = tree.map { targets.placeBeneath(in: $0, skip: plan.skipsBeneath) } ?? (painted: [:], skipped: [:])
        var keyboardUnplaced = false
        if let tree, plan.secure {
            // Windows, not elements, so no page can be beneath them.
            targets.frames[.keyboard, default: []] += KeyboardText.unreadWindows(in: tree).map(Optional.some)
            let bar = KeyboardBar.placement(in: tree)
            targets.frames[.keyboard, default: []] += bar.frames
            keyboardUnplaced = bar.unplaced
            targets.frames[.copyPreview] = CopyPreview.frames(in: tree)
        }
        if let hidden, !hidden.lines.isEmpty {
            let found = try HiddenScreen.targets(hidden.lines, plan: plan)
            for (kind, frames) in found.frames {
                targets.frames[kind.foldsIntoRules ? .rules : kind, default: []] += frames.map { Optional(UIFrame(x: $0.x - 2, y: $0.y - 2, width: $0.width + 4, height: $0.height + 4)) }
            }
            targets.unmatched.removeAll { name in found.matched.contains { name == "--mask-text \($0)" } }
        }
        var recalled: [String] = []
        var skippedRemembered: [MaskKind: Int] = [:]
        if case .found(let found) = remembered {
            for (kind, frames) in found.frames {
                // A remembered element sits on the screen the modal covers, so --mask-skip-beneath leaves it as it leaves one beneath a page.
                if plan.skipsBeneath, kind.skippableBeneath {
                    skippedRemembered[kind, default: 0] += frames.count
                } else {
                    targets.frames[kind, default: []] += frames.map(Optional.some)
                }
            }
            if skippedRemembered.isEmpty { recalled = found.names }
        }
        var unlistedEmails = 0
        if plan.emails, let hidden, hidden.modalShown {
            unlistedEmails = try HiddenScreen.targets(hidden.lines, plan: MaskPlan(emails: true)).frames[.emails]?.count ?? 0
        }
        let beneathFrames = placement.painted
        let kinds = plan.kinds.filter { !$0.foldsIntoRules } + (plan.readsText || !hiddenNodes.isEmpty || targets.frames[.rules]?.isEmpty == false ? [.rules] : [])
        let skipped = plan.skipsBeneath
            ? Dictionary(uniqueKeysWithValues: kinds.filter(\.skippableBeneath).map { ($0, (placement.skipped[$0] ?? 0) + (skippedRemembered[$0] ?? 0)) }) : nil

        var image = capture.image
        var painted: [MaskKind: Int] = [:]
        var beneath: [MaskKind: Int] = [:]
        for kind in MaskKind.allCases where kinds.contains(kind) {
            let rects = { (frames: [UIFrame?]) in
                try SecureMask.pixelRects(
                    frames: frames,
                    subject: subject(of: kind),
                    pixelsPerPoint: capture.upright ? capture.pixelsPerPoint : nil,
                    imageWidth: capture.image.width,
                    imageHeight: capture.image.height
                )
            }
            let all = try rects(targets.frames[kind] ?? [])
            painted[kind] = all.count
            if let covered = beneathFrames[kind], !covered.isEmpty {
                beneath[kind] = try rects(covered).count
            }
            if !all.isEmpty {
                image = try ScreenImage.masked(image, pixelRects: all)
            }
        }
        beneath = beneath.filter { $0.value > 0 }
        painted = painted.filter { !$0.key.ridesWithSecure || $0.value > 0 }
        let unproven = tree.flatMap(Self.unproven) ?? (recalled.isEmpty ? nil : "remembered") ?? (hidden?.unproven == true ? "modal" : nil)
            ?? (remembered.map { if case .off = $0 { "modal" } else { nil } } ?? nil) ?? (keyboardUnplaced ? "keyboard" : nil)
        guard image !== capture.image else {
            return MaskResult(
                capture: capture, painted: painted, beneath: beneath, skipped: skipped, unmatched: targets.unmatched, unproven: unproven,
                remembered: recalled, unlistedEmails: unlistedEmails
            )
        }
        let masked = CapturedScreen(
            image: image, platform: capture.platform, screen: capture.screen, pixelsPerPoint: capture.pixelsPerPoint,
            upright: capture.upright, untouchedPNG: nil
        )
        return MaskResult(
            capture: masked, painted: painted, beneath: beneath, skipped: skipped, unmatched: targets.unmatched, unproven: unproven,
            remembered: recalled, unlistedEmails: unlistedEmails
        )
    }

    nonisolated private static func subject(of kind: MaskKind) -> String {
        switch kind {
        case .secure: "A secure field"
        case .keyboard: "Keyboard text"
        case .copyPreview: "The copy preview"
        case .id: "An element --mask-id matched"
        case .label: "An element --mask-label matched"
        case .labelContains: "An element --mask-label-contains matched"
        case .text: "An element --mask-text matched"
        case .emails: "An email address"
        case .rules: "An element a mask hides"
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
        let tolerance = bands.noiseTolerance
        guard let current = ImageFingerprint(image: rendered.image, excludingTopPixels: exclusion.top, excludingBottomPixels: exclusion.bottom, tolerance: tolerance),
              let before = ImageFingerprint(image: baselineImage, excludingTopPixels: exclusion.top, excludingBottomPixels: exclusion.bottom, tolerance: tolerance),
              var result = ScreenCompare.compare(before, current, threshold: threshold) else {
            throw ImageFailure(detail: "could not compare the capture with \(baselinePath)")
        }
        let diff = try ScreenDiff.compare(
            baseline: baselineImage, current: rendered.image, excludingTop: exclusion.top, excludingBottom: exclusion.bottom, tolerance: tolerance
        )
        result.pixels = ScreenCompare.PixelCounts(changedPixels: diff.changedPixels, comparedPixels: diff.comparedPixels, bounds: diff.bounds)
        return (result, diff.image)
    }

    /// Reads a baseline image, naming the path when it cannot.
    nonisolated static func readBaseline(at path: String) throws -> Data {
        let expanded = (path as NSString).expandingTildeInPath
        let resolved = URL(fileURLWithPath: expanded).resolvingSymlinksInPath().path
        guard let data = UntrustedRead.contents(atPath: resolved, maxBytes: 256 << 20) else {
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

    /// Where a capture goes, and whether the user named the file (`--output` naming a file, so it may replace one).
    struct OutputTarget: Equatable {
        let url: URL
        let userNamed: Bool
    }

    /// What a default capture name starts with: `Screenshot` for a physical iPhone, iPad or Android phone, else the simulator's or emulator's.
    nonisolated static func defaultPrefix(for device: DeviceID) -> String {
        if device.isPhysicalIOSDevice || device.isPhysicalAndroidDevice { return "Screenshot" }
        return device.platform == .android ? "Emulator Screenshot" : "Simulator Screenshot"
    }

    /// A directory or no path gets "<prefix> - <device> - <timestamp>.<ext>" with the device name made safe; missing parent directories are created; nothing is deleted.
    nonisolated static func outputURL(path: String?, prefix: String, deviceName: String, format: ImageFormat, now: Date = Date()) throws -> OutputTarget {
        let fileManager = FileManager.default
        let generatedName = "\(prefix) - \(OutputFile.sanitisedComponent(deviceName)) - \(formatTimestamp(now)).\(format.fileExtension)"
        let providedPath = path?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedPath: String
        var userNamed = false
        if let providedPath, !providedPath.isEmpty {
            resolvedPath = (providedPath as NSString).expandingTildeInPath
            userNamed = true
        } else {
            resolvedPath = generatedName
        }

        let baseURL = resolvedPath.hasPrefix("/")
            ? URL(fileURLWithPath: resolvedPath)
            : URL(fileURLWithPath: fileManager.currentDirectoryPath).appendingPathComponent(resolvedPath)

        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: baseURL.path, isDirectory: &isDirectory), isDirectory.boolValue {
            return OutputTarget(url: baseURL.appendingPathComponent(generatedName), userNamed: false)
        }

        let directoryURL = baseURL.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: directoryURL.path) {
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true, attributes: nil)
        }
        return OutputTarget(url: baseURL, userNamed: userNamed)
    }

    /// Writes a capture: a file the user named is replaced whole (only an image or video file they own); a generated name is never overwritten and takes " 2", " 3" when taken. Returns where it went.
    nonisolated static func write(_ data: Data, to target: OutputTarget) throws -> URL {
        do {
            if target.userNamed {
                try OutputFile.replace(data, at: target.url.path)
                return target.url
            }
            return URL(fileURLWithPath: try OutputFile.writeNew(data, at: target.url.path))
        } catch let error as OutputFileError {
            throw CLIError(errorDescription: error.message, reason: .screenshotFailed)
        }
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
