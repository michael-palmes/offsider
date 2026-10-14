import ArgumentParser
import CoreGraphics
import Foundation
import OffsiderCore
import Testing
@testable import Offsider

/// A fake whose orientation reads are scripted, holding the last.
@MainActor
class TurningFakeBackend: FakeDeviceBackend, OrientationControlling {
    var orientations: [DeviceOrientation?]
    private(set) var orientationReads = 0

    init(orientations: [DeviceOrientation?], screenshots: [Data], screen: UIScreenInfo?) {
        self.orientations = orientations
        super.init(trees: [], screenshots: screenshots, screen: screen)
    }

    func orientation(of id: DeviceID) async throws -> DeviceOrientation? {
        defer { orientationReads += 1 }
        return orientations[min(orientationReads, orientations.count - 1)]
    }

    func requestOrientation(_ orientation: DeviceOrientation, on id: DeviceID) async throws {}
}

/// Fails its first capture, as a screencap or broker hiccup can, then serves its screenshots.
final class FlakyFirstCaptureBackend: TurningFakeBackend {
    private var failed = false

    override func screenshotPNG(for id: DeviceID) async throws -> Data {
        guard failed else {
            failed = true
            throw CLIError(errorDescription: "capture failed once")
        }
        return try await super.screenshotPNG(for: id)
    }
}

/// Fails every tree read, as a device that stopped answering does.
final class UnreadableTreeBackend: FakeDeviceBackend {
    override func accessibilityTree(for id: DeviceID, point: UIPoint?) async throws -> UITree {
        throw CLIError(errorDescription: "tree read failed")
    }
}

@Suite("Video masks")
@MainActor
struct VideoMaskTests {
    static let device = DeviceID(rawValue: "ABCDEF00-0000-4000-8000-00000000ABCD", platform: .ios)
    static let black: [UInt8] = [0, 0, 0]
    static let white: [UInt8] = [255, 255, 255]

    // MARK: - Refusal policy

    @Test("tree masks and a run masking emails or ids refuse video; password masking checks the screen; --unmasked records with a warning", arguments: [
        ([String](), nil as RunMasks?, false, false, "record"),
        ([], nil, true, false, "check"),
        ([], RunMasks(), false, false, "record"),
        ([], RunMasks(secure: true), false, false, "check"),
        (["--mask-secure"], nil, true, false, "refuse:cannot apply --mask-secure"),
        (["--mask-id", "--mask-text"], nil, true, false, "refuse:cannot apply --mask-id and --mask-text"),
        (["--mask-emails"], nil, true, true, "usage:--unmasked records without the masks --mask-emails asks for"),
        ([], RunMasks.defaults, true, false, "refuse:while the evidence run masks email addresses"),
        ([], RunMasks(ids: ["account-number"]), false, false, "refuse:while the evidence run masks id account-number"),
        ([], RunMasks(secure: true), true, true, "warn:(the evidence run masks password fields)"),
        ([], nil, true, true, "warn:(password fields are masked by default)"),
        ([], nil, false, true, "warn:nothing in this video is masked by the accessibility tree."),
    ])
    func policy(flags: [String], run: RunMasks?, secureByDefault: Bool, unmasked: Bool, expected: String) {
        let decision = VideoMaskPolicy.decide(command: "record-video", treeFlags: flags, run: run, secureByDefault: secureByDefault, unmasked: unmasked)
        let (kind, text) = expected.split(separator: ":", maxSplits: 1).map(String.init).paddedPair
        switch decision {
        case .record(let warning):
            #expect(kind == (warning == nil ? "record" : "warn"))
            if let warning { #expect(warning.contains(text), "\(warning)") }
        case .checkSecureField:
            #expect(kind == "check")
        case .refuse(let message):
            #expect(kind == "refuse")
            #expect(message.contains(text), "\(message)")
            #expect(message.contains("screenshot"))
            #expect(message.contains("--unmasked"))
        case .usage(let message):
            #expect(kind == "usage")
            #expect(message.contains(text), "\(message)")
        }
    }

    @Test("video masks password fields by default unless OFFSIDER_MASK_SECURE turns it off")
    func secureDefault() throws {
        let options = try VideoMaskOptions.parse([])
        #expect(try options.requireMaskable(command: "record-video", environment: [:]))
        #expect(try options.requireMaskable(command: "record-video", environment: ["OFFSIDER_MASK_SECURE": "0"]) == false)
    }

    @Test("video refuses with video_unmasked while a password field is on screen, or when the tree cannot be read")
    func secureFieldRefusal() async throws {
        let screen = UIScreenInfo(width: 390, height: 844, scale: 3)
        let shown = FakeDeviceBackend(trees: [FakeUI.tree(width: 390, height: 844, [SecureTextTests.passwordField()])], screen: screen)
        let error = await #expect(throws: CLIError.self) {
            try await VideoMaskOptions.requireNoSecureField(command: "record-video", backend: shown, device: Self.device)
        }
        #expect(error?.reason == .videoUnmasked)
        #expect(error?.userFacingDescription.contains("password field is on screen") == true)
        #expect(error?.userFacingDescription.contains("--unmasked") == true)

        let below = FakeDeviceBackend(trees: [FakeUI.tree(width: 390, height: 844, [SecureTextTests.passwordField(frame: FakeUI.frame(16, 2000, 361, 44))])], screen: screen)
        try await VideoMaskOptions.requireNoSecureField(command: "record-video", backend: below, device: Self.device)

        let unreadable = UnreadableTreeBackend(trees: [], screen: screen)
        let failed = await #expect(throws: CLIError.self) {
            try await VideoMaskOptions.requireNoSecureField(command: "stream-video", backend: unreadable, device: Self.device)
        }
        #expect(failed?.reason == .videoUnmasked)
        #expect(failed?.userFacingDescription.contains("could not read the accessibility tree") == true)
    }

    @Test("a frame is admitted only when the reads before and after it match the first frame's orientation and its size does too", arguments: [
        ([DeviceOrientation?.some(.portrait), .portrait, .portrait], [true, true, true]),
        ([.portrait, .landscapeLeft, .portrait, .portrait], [true, false, false, true]),
        ([.portrait, nil, .portrait, .portrait], [true, false, false, true]),
        ([.landscapeLeft, .landscapeLeft], [false, false]),
    ])
    func gate(afters: [DeviceOrientation?], admitted: [Bool]) {
        var gate = VideoFrameGate(orientation: .portrait, width: 100, height: 200)
        #expect(afters.map { gate.admits(width: 100, height: 200, after: $0) } == admitted)
    }

    @Test("a frame of another size is not admitted, even in the same orientation")
    func gateSize() {
        var gate = VideoFrameGate(orientation: .portrait, width: 100, height: 200)
        let turned = gate.admits(width: 200, height: 100, after: .portrait)
        let upright = gate.admits(width: 100, height: 200, after: .portrait)
        #expect(!turned)
        #expect(upright)
    }

    @Test("the recording report keeps its schema order and counts regions under maskedBy")
    func report() {
        #expect(VideoRecordingReport(path: "/tmp/a.mp4", frames: 31, heldFrames: 4, regions: 2, unmasked: false).jsonLine()
            == #"{"version":1,"path":"/tmp/a.mp4","frames":31,"heldFrames":4,"maskedBy":{"region":2},"unmasked":false}"#)
        #expect(VideoRecordingReport(path: "/tmp/a.mp4", frames: 1, heldFrames: 0, regions: 0, unmasked: true).jsonLine()
            == #"{"version":1,"path":"/tmp/a.mp4","frames":1,"heldFrames":0,"maskedBy":{},"unmasked":true}"#)
    }

    // MARK: - Frames

    static func whitePNG(width: Int, height: Int) throws -> Data {
        try ScreenImage.encode(TestImages.make(width: width, height: height, background: 255), as: .png)
    }

    @Test("regions are painted in points on the upright frame of a landscape simulator, whose framebuffer stays portrait")
    func rotatedRegion() async throws {
        let screen = UIScreenInfo(width: 844, height: 390, scale: 3, rotation: .landscape)
        let backend = TurningFakeBackend(orientations: [.landscapeRight], screenshots: [try Self.whitePNG(width: 1170, height: 2532)], screen: screen)
        let source = VideoFrameSource(backend: backend, device: Self.device, scale: 1, regions: [PointRegion(x: 10, y: 20, width: 100, height: 50)])

        let first = try await source.start()
        let next = try await source.next()

        for image in [first, next.image] {
            #expect(image.width == 2532 && image.height == 1170)
            #expect(ScreenshotMaskTests.pixel(image, 50 * 3, 40 * 3) == Self.black)
            #expect(ScreenshotMaskTests.pixel(image, 200 * 3, 40 * 3) == Self.white)
            #expect(ScreenshotMaskTests.pixel(image, 50 * 3, 100 * 3) == Self.white)
        }
        #expect(!next.held)
        #expect(source.painted == 1)
    }

    @Test("a frame taken while the screen turned is replaced by the last masked frame and counted")
    func heldFrames() async throws {
        let screen = UIScreenInfo(width: 390, height: 844, scale: 3, rotation: .portrait)
        let backend = TurningFakeBackend(
            orientations: [.portrait, .portrait, .portrait, .landscapeLeft, .portrait, .portrait],
            screenshots: [try Self.whitePNG(width: 1170, height: 2532)],
            screen: screen
        )
        let source = VideoFrameSource(backend: backend, device: Self.device, scale: 1, regions: [PointRegion(x: 0, y: 0, width: 50, height: 50)])

        _ = try await source.start()
        let good = try await source.next()
        let turned = try await source.next()
        let after = try await source.next()
        let back = try await source.next()

        #expect([good.held, turned.held, after.held, back.held] == [false, true, true, false])
        #expect(turned.image === good.image)
        #expect(after.image === good.image)
        #expect(ScreenshotMaskTests.pixel(back.image, 10, 10) == Self.black)
    }

    @Test("a region that cannot be mapped to points ends the recording before its first frame")
    func unmappableRegion() async throws {
        let backend = TurningFakeBackend(orientations: [.portrait], screenshots: [try Self.whitePNG(width: 1170, height: 2532)], screen: nil)
        let source = VideoFrameSource(backend: backend, device: Self.device, scale: 1, regions: [PointRegion(x: 0, y: 0, width: 50, height: 50)])

        let error = await #expect(throws: CLIError.self) { _ = try await source.start() }
        #expect(error?.reason == .maskUnproven)
        #expect(error?.userFacingDescription.contains("Nothing was recorded") == true)
    }

    @Test("an orientation that never reads steadily ends the recording before its first frame")
    func unsteadyOrientation() async throws {
        let screen = UIScreenInfo(width: 390, height: 844, scale: 3, rotation: .portrait)
        let backend = TurningFakeBackend(orientations: [nil], screenshots: [try Self.whitePNG(width: 1170, height: 2532)], screen: screen)
        let source = VideoFrameSource(backend: backend, device: Self.device, scale: 1, regions: [PointRegion(x: 0, y: 0, width: 50, height: 50)])

        let error = await #expect(throws: CLIError.self) { _ = try await source.start() }
        #expect(error?.reason == .maskUnproven)
    }

    @Test("without regions no orientation is read and every frame is used")
    func noRegions() async throws {
        let screen = UIScreenInfo(width: 390, height: 844, scale: 3, rotation: .portrait)
        let backend = TurningFakeBackend(orientations: [.landscapeLeft], screenshots: [try Self.whitePNG(width: 1170, height: 2532)], screen: screen)
        let source = VideoFrameSource(backend: backend, device: Self.device, scale: 1, regions: [])

        _ = try await source.start()
        let next = try await source.next()

        #expect(!next.held)
        #expect(backend.orientationReads == 0)
        #expect(ScreenshotMaskTests.pixel(next.image, 10, 10) == Self.white)
    }

    @Test("without regions a stream reports a failed first capture and takes the next frame")
    func streamRetriesFirstFrame() async throws {
        let screen = UIScreenInfo(width: 390, height: 844, scale: 3, rotation: .portrait)
        let backend = FlakyFirstCaptureBackend(orientations: [.portrait], screenshots: [try Self.whitePNG(width: 1170, height: 2532)], screen: screen)
        let source = VideoFrameSource(backend: backend, device: Self.device, scale: 1, regions: [])
        var reported: [String] = []

        let first = try await source.firstFrame { reported.append($0.localizedDescription) }
        let next = try await source.next()

        #expect(first == nil)
        #expect(reported == ["capture failed once"])
        #expect(next.image.width == 1170 && !next.held)
    }

    @Test("with a region a failed first capture ends the stream before anything is sent")
    func regionStreamStopsOnFirstFrame() async throws {
        let screen = UIScreenInfo(width: 390, height: 844, scale: 3, rotation: .portrait)
        let backend = FlakyFirstCaptureBackend(orientations: [.portrait], screenshots: [try Self.whitePNG(width: 1170, height: 2532)], screen: screen)
        let source = VideoFrameSource(backend: backend, device: Self.device, scale: 1, regions: [PointRegion(x: 0, y: 0, width: 50, height: 50)])
        var reported: [String] = []

        await #expect(throws: CLIError.self) { _ = try await source.firstFrame { reported.append($0.localizedDescription) } }
        #expect(reported.isEmpty)
    }

    // MARK: - Commands

    @Test("video usage errors exit 64", arguments: [
        (["record-video", "--mask-secure", "--unmasked", "--device", "ABCDEF00-0000-4000-8000-00000000ABCD"], "--unmasked records without the masks --mask-secure asks for"),
        (["stream-video", "--format", "bgra", "--mask-region", "0,0,10,10", "--device", "ABCDEF00-0000-4000-8000-00000000ABCD"], "--format bgra passes the device's own video through"),
        (["record-video", "--mask-region", "0,0,0,10", "--device", "ABCDEF00-0000-4000-8000-00000000ABCD"], "--mask-region 0,0,0,10 has no area"),
        (["record-video", "--mask-skip-beneath", "--device", "ABCDEF00-0000-4000-8000-00000000ABCD"], "Unknown option '--mask-skip-beneath'"),
    ])
    func usageErrors(arguments: [String], message: String) {
        do {
            _ = try OffsiderCommand.parseAsRoot(arguments)
            Issue.record("expected a usage error for \(arguments)")
        } catch {
            #expect(OffsiderCommand.exitCode(for: error) == .validationFailure)
            #expect(OffsiderCommand.message(for: error).contains(message), "\(OffsiderCommand.message(for: error))")
        }
    }

    static func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("offsider-video-mask-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("a run with masks refuses record-video before it routes, and writes no file")
    func maskedRunRefuses() async throws {
        let folder = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let environment = ["OFFSIDER_RUN": folder.path]
        let started = try await TestHelpers.runOffsiderCommandSeparated("run start '\(folder.path)' --mask-secure", environment: environment)
        #expect(started.exitCode == 0, "\(started.stderr)")
        let before = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        let output = folder.appendingPathComponent("clip.mp4").path

        let result = try await TestHelpers.runOffsiderCommandSeparated(
            "record-video --device \(Self.device.rawValue) --output '\(output)' --json", environment: environment
        )

        #expect(result.exitCode == 1)
        #expect(result.stdout.contains(#""reason":"video_unmasked""#), "\(result.stdout)")
        #expect(result.stderr.contains("the evidence run masks email addresses"))
        #expect(!FileManager.default.fileExists(atPath: output))
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted() == before)
    }

    @Test("a default run, which masks emails, refuses stream-video before anything is streamed")
    func defaultRunRefusesStream() async throws {
        let folder = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let environment = ["OFFSIDER_RUN": folder.path]
        _ = try await TestHelpers.runOffsiderCommandSeparated("run start '\(folder.path)'", environment: environment)
        let result = try await TestHelpers.runOffsiderCommandSeparated("stream-video --device \(Self.device.rawValue)", environment: environment)
        #expect(result.exitCode == 1)
        #expect(result.stdout.isEmpty)
        #expect(result.stderr.contains("stream-video will not run while the evidence run masks email addresses"))
    }

    @Test("--unmasked records past the refusal with a warning, as far as the device")
    func unmaskedReachesDevice() async throws {
        let result = try await TestHelpers.runOffsiderCommandSeparated(
            "record-video --unmasked --device \(Self.device.rawValue) --json", environment: ["OFFSIDER_MASK_SECURE": "1"]
        )
        #expect(result.exitCode == 7)
        #expect(result.stdout.contains(#""reason":"device_not_found""#), "\(result.stdout)")
        #expect(result.stderr.contains("Warning: --unmasked: nothing in this video is masked"))
    }
}

private extension Array where Element == String {
    var paddedPair: (String, String) { (self.first ?? "", count > 1 ? self[1] : "") }
}
