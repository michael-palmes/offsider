import ArgumentParser
import CoreGraphics
import Foundation
import OffsiderCore

/// The mask options `record-video` and `stream-video` share: tree masks only to refuse them, regions painted on every frame.
struct VideoMaskOptions: ParsableArguments {
    @Flag(name: .customLong("mask-secure"), help: "Refused with video_unmasked: use screenshot --mask-secure for masked evidence.")
    var maskSecure = false

    @Option(name: .customLong("mask-id"), parsing: .upToNextOption, help: ArgumentHelp("Refused with video_unmasked: use screenshot --mask-id.", valueName: "id"))
    var maskIDs: [String] = []

    @Option(name: .customLong("mask-label"), parsing: .upToNextOption, help: ArgumentHelp("Refused with video_unmasked: use screenshot --mask-label.", valueName: "text"))
    var maskLabels: [String] = []

    @Option(name: .customLong("mask-label-contains"), parsing: .upToNextOption, help: ArgumentHelp("Refused with video_unmasked: use screenshot --mask-label-contains.", valueName: "text"))
    var maskLabelContains: [String] = []

    @Option(name: .customLong("mask-text"), parsing: .upToNextOption, help: ArgumentHelp("Refused with video_unmasked: use screenshot --mask-text.", valueName: "regex"))
    var maskTexts: [String] = []

    @Flag(name: .customLong("mask-emails"), help: "Refused with video_unmasked: use screenshot --mask-emails.")
    var maskEmails = false

    @Option(name: .customLong("mask-region"), parsing: .upToNextOption, help: ArgumentHelp("Paint this rectangle, in points as tap takes them, black on every frame; a frame taken in another orientation is replaced by the last good one. Repeatable.", valueName: "x,y,w,h"))
    var maskRegions: [String] = []

    @Flag(name: .customLong("unmasked"), help: "Record although a password field is on screen or the evidence run asks for masks video cannot apply; prints a warning.")
    var unmasked = false

    /// The tree-mask flags given, in help order.
    var treeFlags: [String] {
        [
            maskSecure ? "--mask-secure" : nil,
            maskIDs.isEmpty ? nil : "--mask-id",
            maskLabels.isEmpty ? nil : "--mask-label",
            maskLabelContains.isEmpty ? nil : "--mask-label-contains",
            maskTexts.isEmpty ? nil : "--mask-text",
            maskEmails ? "--mask-emails" : nil,
        ].compactMap { $0 }
    }

    func regions() throws -> [PointRegion] {
        try maskRegions.map { try PointRegion.parse($0, option: "--mask-region") }
    }

    func validate() throws {
        do {
            _ = try regions()
        } catch let error as ScreenRegionError {
            throw ValidationError(error.message)
        }
        if case .usage(let message) = VideoMaskPolicy.decide(command: "", treeFlags: treeFlags, run: nil, secureByDefault: false, unmasked: unmasked) {
            throw ValidationError(message)
        }
    }

    /// Before routing, so a refused recording starts no device stack and writes no file; prints the `--unmasked` warning.
    /// True when `requireNoSecureField` must read the tree before the first frame.
    @MainActor
    @discardableResult
    func requireMaskable(command: String, environment: [String: String] = ProcessInfo.processInfo.environment) throws -> Bool {
        let run = try EvidenceRecorder.current.run()?.masks
        switch VideoMaskPolicy.decide(
            command: command, treeFlags: treeFlags, run: run,
            secureByDefault: Screenshot.masksSecure(flag: nil, environment: environment), unmasked: unmasked
        ) {
        case .record(let warning?):
            Console.current.line("Warning: \(warning)", person: .warning("This video is not masked; password fields will show"))
            return false
        case .record(nil):
            // offsider.mask.json's masks cannot be painted on video either, so its one tree read checks them too.
            return try MaskConfigs.current().map { !$0.config.isEmpty } ?? false
        case .checkSecureField:
            return true
        case .refuse(let message):
            throw CLIError(errorDescription: message, reason: .videoUnmasked)
        case .usage(let message):
            throw ValidationError(message)
        }
    }

    /// Reads one tree before the first frame and refuses with `video_unmasked` when it shows a password field, or anything
    /// `offsider.mask.json` masks, or cannot be read.
    @MainActor
    static func requireNoSecureField(command: String, backend: any DeviceBackend, device: DeviceID) async throws {
        let config = try MaskConfigs.current()
        let tree: UITree
        do {
            if let reader = backend as? any MaskTreeReading {
                tree = try await reader.maskTree(for: device)
            } else {
                tree = try await backend.accessibilityTree(for: device)
            }
        } catch {
            throw CLIError(errorDescription: VideoMaskPolicy.unreadableRefusal(command: command, error: OffsiderCommand.message(for: error)), reason: .videoUnmasked)
        }
        if VideoMaskPolicy.showsSecureField(tree) {
            throw CLIError(errorDescription: VideoMaskPolicy.secureFieldRefusal(command: command), reason: .videoUnmasked)
        }
        if let config, let shown = try configMatch(config.config, in: tree) {
            throw CLIError(
                errorDescription: "\(command) will not start while \(shown), which \(MaskConfig.fileName) masks, is on screen: video cannot be masked reliably frame by frame. "
                    + "Leave that screen first, use `screenshot`, which masks it, or pass --unmasked to record anyway.",
                reason: .videoUnmasked
            )
        }
    }

    /// The first selector of the file that matches an element on screen, as `--mask-id x` names it; nil when none does.
    nonisolated static func configMatch(_ config: MaskConfig, in tree: UITree) throws -> String? {
        let viewport = tree.viewport
        func onScreen(_ node: UINode) -> Bool {
            guard let viewport, let frame = node.frame else { return true }
            return frame.isVisible(in: viewport)
        }
        let selectors = config.ids.map { ("--mask-id \($0)", AccessibilityQuery.id($0)) } + config.labels.map { ("--mask-label \($0)", AccessibilityQuery.label($0)) }
            + config.labelContains.map { ("--mask-label-contains \($0)", AccessibilityQuery.labelContains($0)) }
        for (name, query) in selectors where AccessibilityTargetResolver.candidates(roots: tree.roots, query: query, elementType: nil).matches.contains(where: onScreen) {
            return name
        }
        let texts = try MaskConfig(valuePatterns: config.valuePatterns, emails: config.emails).plan.textTargets(in: tree)
        for group in texts.groups where group.nodes.contains(where: onScreen) {
            return group.kind == .emails ? "an email address" : "text a value pattern matches"
        }
        return nil
    }
}

/// One frame for the video, and whether it repeats the last good frame because this one could not be masked.
struct VideoFrame {
    let image: CGImage
    let held: Bool
}

/// Video frames, upright, with `--mask-region` painted; the device scales them only when it captures frames itself.
@MainActor
final class VideoFrameSource {
    let backend: any DeviceBackend
    let device: DeviceID
    let scale: Double
    let regions: [PointRegion]
    private let capturer: (any FrameCapturing)?
    private var screen: UIScreenInfo?
    private var gate: VideoFrameGate?
    private var lastGood: CGImage?
    /// Rectangles painted on each frame.
    private(set) var painted = 0

    init(backend: any DeviceBackend, device: DeviceID, scale: Double, regions: [PointRegion]) {
        self.backend = backend
        self.device = device
        self.scale = scale
        self.regions = regions
        self.capturer = backend as? any FrameCapturing
    }

    /// True when `scale` was applied by the device, so the writer must not scale again.
    var scalesItself: Bool { capturer != nil }

    /// The first frame; with regions, it fixes the orientation and size every later frame must match, and nothing is recorded when it cannot.
    func start() async throws -> CGImage {
        guard !regions.isEmpty else {
            screen = try? await backend.screenInfo(for: device)
            let image = try await capture().image
            return image
        }
        guard let turner = backend as? any OrientationControlling else {
            throw Self.unplaceable("\(device.rawValue) does not report its orientation")
        }
        for _ in 0..<Self.startAttempts {
            let before = try? await turner.orientation(of: device)
            // Between two equal reads, so the points every frame is mapped with match the reference orientation.
            screen = try? await backend.screenInfo(for: device)
            let capture = try await capture()
            let after = try? await turner.orientation(of: device)
            guard let before, before == after else { continue }
            let masked: ScreenCapture.MaskResult
            do {
                masked = try ScreenCapture.masking(capture, plan: MaskPlan(regions: regions), tree: nil)
            } catch is MaskUnproven {
                throw Self.unplaceable("the capture could not be mapped to points")
            }
            gate = VideoFrameGate(orientation: before, width: capture.image.width, height: capture.image.height)
            painted = masked.painted[.region] ?? 0
            lastGood = masked.capture.image
            return masked.capture.image
        }
        throw Self.unplaceable("the screen's orientation could not be read steadily")
    }

    /// `start()` for a stream: without regions a failed first capture is reported and nil, so the next tick retries it.
    func firstFrame(reporting report: (any Error) -> Void) async throws -> CGImage? {
        do {
            return try await start()
        } catch where regions.isEmpty {
            report(error)
            return nil
        }
    }

    /// The next frame; a frame not proven in the first frame's orientation and size is replaced by the last good one.
    func next() async throws -> VideoFrame {
        guard let turner = backend as? any OrientationControlling, var gate, let lastGood else {
            let image = try await capture().image
                return VideoFrame(image: image, held: false)
        }
        let captured: Result<CapturedScreen, any Error>
        do {
            captured = .success(try await capture())
        } catch {
            captured = .failure(error)
        }
        let after = try? await turner.orientation(of: device)
        let size = (try? captured.get()).map { ($0.image.width, $0.image.height) } ?? (0, 0)
        // A failed capture still records the read after it, which the next frame's proof starts from.
        let admitted = gate.admits(width: size.0, height: size.1, after: after)
        self.gate = gate
        let capture = try captured.get()
        guard admitted, let masked = try? ScreenCapture.masking(capture, plan: MaskPlan(regions: regions), tree: nil) else {
            if !holding {
                holding = true
                Console.current.line(
                    "The screen left the orientation the recording started in, so --mask-region cannot be placed; repeating the last masked frame until it returns.",
                    person: .warning("The screen turned, so --mask-region holds the last masked frame until it turns back")
                )
            }
            return VideoFrame(image: lastGood, held: true)
        }
        holding = false
        self.lastGood = masked.capture.image
        return VideoFrame(image: masked.capture.image, held: false)
    }

    private var holding = false
    private static let startAttempts = 3

    private static func unplaceable(_ why: String) -> CLIError {
        CLIError(errorDescription: "A --mask-region cannot be placed: \(why). Nothing was recorded. Retry when the screen is still, or record without --mask-region.", reason: .maskUnproven)
    }

    /// The device's frame with the screen read at the start, turned upright as `screenshot` does.
    private func capture() async throws -> CapturedScreen {
        if let capturer {
            let image = try await capturer.captureFrame(for: device, scale: scale)
            let pixelsPerPoint = screen.flatMap {
                ScreenGeometry.pixelsPerPoint(imageWidth: image.width, imageHeight: image.height, screenWidth: $0.width, screenHeight: $0.height)
            }
            let upright = screen.map { (image.width >= image.height) == ($0.width >= $0.height) } ?? true
            return CapturedScreen(image: image, platform: device.platform, screen: screen, pixelsPerPoint: pixelsPerPoint, upright: upright, untouchedPNG: nil)
        }
        return try ScreenCapture.make(png: try await backend.screenshotPNG(for: device), platform: device.platform, screen: screen)
    }
}
