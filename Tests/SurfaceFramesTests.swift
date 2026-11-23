import ArgumentParser
import AVFoundation
import CoreGraphics
import Foundation
import OffsiderCore
import Testing
@testable import Offsider

/// A display surface in memory, BGRA with padded rows; `onLock` runs inside each locked read, as a compositor drawing mid-copy would.
final class FakeSurface: FrameSurface {
    let width: Int
    let height: Int
    let bytesPerRow: Int
    var bytes: [UInt8]
    var seed: UInt32 = 1
    var onLock: ((FakeSurface) -> Void)?
    private(set) var locks = 0

    init(width: Int, height: Int, fill: [UInt8] = [255, 255, 255, 255]) {
        self.width = width
        self.height = height
        self.bytesPerRow = width * 4 + 64
        self.bytes = [UInt8](repeating: 0, count: bytesPerRow * height)
        paint(0, 0, width, height, fill)
    }

    /// `bgra` over the rectangle, moving the seed as a redraw does.
    func paint(_ x: Int, _ y: Int, _ w: Int, _ h: Int, _ bgra: [UInt8]) {
        for row in y..<(y + h) {
            for column in x..<(x + w) {
                let at = row * bytesPerRow + column * 4
                bytes.replaceSubrange(at..<(at + 4), with: bgra)
            }
        }
        seed &+= 1
    }

    func withLockedPixels<T>(_ body: (UnsafeRawBufferPointer, Int, Int, Int) throws -> T) throws -> T? {
        locks += 1
        let snapshot = bytes
        onLock?(self)
        return try snapshot.withUnsafeBytes { try body($0, width, height, bytesPerRow) }
    }

    static let red: [UInt8] = [0, 0, 255, 255]
    static let blue: [UInt8] = [255, 0, 0, 255]
}

/// An iOS simulator whose frames come from a `FakeSurface`, read as the framebuffer route reads them.
@MainActor
final class SurfaceFakeBackend: TurningFakeBackend, FullRateFrameCapturing {
    let surface: FakeSurface
    private let frames: SurfaceFrames
    private(set) var ended = 0
    var onFrame: ((FakeSurface) -> Void)?

    init(surface: FakeSurface, screen: UIScreenInfo, orientations: [DeviceOrientation?] = [.portrait]) {
        self.surface = surface
        self.frames = SurfaceFrames(quarterTurns: screen.rotation?.uprightQuarterTurnsCounterclockwise ?? 0, scale: 1)
        super.init(orientations: orientations, screenshots: [], screen: screen)
    }

    func captureFrame(for id: DeviceID, scale: Double) async throws -> CGImage {
        try #require(try await changedFrame(for: id, scale: scale, skipUnchanged: false))
    }

    func changedFrame(for id: DeviceID, scale: Double, skipUnchanged: Bool) async throws -> CGImage? {
        onFrame?(surface)
        guard case .image(let image) = try frames.next(from: surface, skipUnchanged: skipUnchanged) else { return nil }
        return image
    }

    func useScreen(_ screen: UIScreenInfo?, for id: DeviceID) {}

    func requireFullRate(fps: Int, for id: DeviceID) async throws {}

    func endFrames(for id: DeviceID) { ended += 1 }
}

@Suite("Simulator video frames from the framebuffer")
@MainActor
struct SurfaceFramesTests {
    static let device = DeviceID(rawValue: "00000000-0000-0000-0000-000000000001", platform: .ios)

    static func marked(width: Int = 6, height: Int = 10) -> FakeSurface {
        let surface = FakeSurface(width: width, height: height)
        surface.paint(width - 1, 0, 1, 1, FakeSurface.red)
        surface.paint(0, height - 1, 2, 1, FakeSurface.blue)
        return surface
    }

    static func image(_ frame: SurfaceFrames.Frame) throws -> CGImage {
        guard case .image(let image) = frame else { throw ImageFailure(detail: "expected a frame") }
        return image
    }

    static func samePixels(_ a: CGImage, _ b: CGImage) -> Bool {
        guard a.width == b.width, a.height == b.height else { return false }
        for y in 0..<a.height {
            for x in 0..<a.width where ScreenshotMaskTests.pixel(a, x, y) != ScreenshotMaskTests.pixel(b, x, y) {
                return false
            }
        }
        return true
    }

    @Test("a surface whose seed has not moved writes no new frame, and reads nothing")
    func unchangedSeed() throws {
        let surface = Self.marked()
        let frames = SurfaceFrames(quarterTurns: 0, scale: 1)

        _ = try Self.image(try frames.next(from: surface, skipUnchanged: true))
        let again = try frames.next(from: surface, skipUnchanged: true)

        guard case .unchanged = again else { Issue.record("expected no new frame"); return }
        #expect(surface.locks == 1)
        surface.paint(0, 0, 1, 1, FakeSurface.red)
        let changed = try Self.image(try frames.next(from: surface, skipUnchanged: true))
        #expect(ScreenshotMaskTests.pixel(changed, 0, 0) == [255, 0, 0])
    }

    @Test("without skipping, an unchanged surface is read again")
    func unchangedReadWhenAsked() throws {
        let surface = Self.marked()
        let frames = SurfaceFrames(quarterTurns: 0, scale: 1)

        _ = try frames.next(from: surface, skipUnchanged: true)
        _ = try Self.image(try frames.next(from: surface, skipUnchanged: false))

        #expect(surface.locks == 2)
    }

    @Test("a seed that moves during the copy is a torn frame, so the surface is copied once more and the second copy is kept")
    func tornCopy() throws {
        let surface = Self.marked()
        surface.onLock = { surface in
            surface.onLock = nil
            surface.paint(0, 0, surface.width, surface.height, FakeSurface.blue)
        }
        let frames = SurfaceFrames(quarterTurns: 0, scale: 1)

        let image = try Self.image(try frames.next(from: surface, skipUnchanged: true))

        #expect(surface.locks == 2)
        #expect(ScreenshotMaskTests.pixel(image, 5, 0) == [0, 0, 255])
        guard case .unchanged = try frames.next(from: surface, skipUnchanged: true) else {
            Issue.record("the second copy was whole, so its seed counts as written"); return
        }
    }

    @Test("a surface torn twice is copied only twice, and its next frame is read whatever its seed")
    func tornTwice() throws {
        let surface = Self.marked()
        surface.onLock = { $0.seed &+= 1 }
        let frames = SurfaceFrames(quarterTurns: 0, scale: 1)

        _ = try Self.image(try frames.next(from: surface, skipUnchanged: true))
        #expect(surface.locks == 2)
        surface.onLock = nil
        _ = try Self.image(try frames.next(from: surface, skipUnchanged: true))
        #expect(surface.locks == 3)
    }

    @Test("each quarter turn matches the screenshot route's upright frame", arguments: [1, 2, 3])
    func turns(_ turns: Int) throws {
        let surface = Self.marked()
        let native = try Self.image(try SurfaceFrames(quarterTurns: 0, scale: 1).next(from: surface, skipUnchanged: false))
        let turned = try Self.image(try SurfaceFrames(quarterTurns: turns, scale: 1).next(from: surface, skipUnchanged: false))

        #expect(Self.samePixels(turned, try ScreenImage.rotated(native, quarterTurnsCounterclockwise: turns)))
    }

    @Test("--scale 0.5 halves both sides, turned or not", arguments: [0, 1])
    func scaled(_ turns: Int) throws {
        let surface = FakeSurface(width: 100, height: 200)
        let image = try Self.image(try SurfaceFrames(quarterTurns: turns, scale: 0.5).next(from: surface, skipUnchanged: false))

        #expect((image.width, image.height) == (turns == 1 ? (100, 50) : (50, 100)))
        #expect(ScreenshotMaskTests.pixel(image, 10, 10) == [255, 255, 255])
    }

    @Test("a surface that cannot be locked fails the frame rather than writing one")
    func unlockable() {
        final class Unlockable: FrameSurface {
            var seed: UInt32 = 1
            func withLockedPixels<T>(_ body: (UnsafeRawBufferPointer, Int, Int, Int) throws -> T) throws -> T? { nil }
        }
        #expect(throws: ImageFailure.self) { _ = try SurfaceFrames(quarterTurns: 0, scale: 1).next(from: Unlockable(), skipUnchanged: false) }
    }

    @Test("a landscape simulator's portrait framebuffer comes out upright, with the region painted where tap would land")
    func landscapeRegion() async throws {
        let screen = UIScreenInfo(width: 844, height: 390, scale: 3, rotation: .landscape)
        let backend = SurfaceFakeBackend(surface: FakeSurface(width: 1170, height: 2532), screen: screen, orientations: [.landscapeRight])
        let source = VideoFrameSource(backend: backend, device: Self.device, scale: 1, regions: [PointRegion(x: 10, y: 20, width: 100, height: 50)])

        let first = try await source.start()
        backend.surface.paint(0, 0, 10, 10, FakeSurface.blue)
        let next = try await source.next()

        for image in [first, next.image] {
            #expect(image.width == 2532 && image.height == 1170)
            #expect(ScreenshotMaskTests.pixel(image, 50 * 3, 40 * 3) == VideoMaskTests.black)
            #expect(ScreenshotMaskTests.pixel(image, 200 * 3, 40 * 3) == VideoMaskTests.white)
            #expect(ScreenshotMaskTests.pixel(image, 50 * 3, 100 * 3) == VideoMaskTests.white)
        }
        #expect(!next.held && !next.unchanged)
        #expect(source.painted == 1)
    }

    @Test("an unchanged screen repeats the last masked frame without reading the orientation again")
    func unchangedWithRegion() async throws {
        let screen = UIScreenInfo(width: 390, height: 844, scale: 3, rotation: .portrait)
        let backend = SurfaceFakeBackend(surface: FakeSurface(width: 1170, height: 2532), screen: screen)
        let source = VideoFrameSource(backend: backend, device: Self.device, scale: 1, regions: [PointRegion(x: 0, y: 0, width: 50, height: 50)])

        let first = try await source.start()
        let reads = backend.orientationReads
        let next = try await source.next()

        #expect(next.unchanged && next.image === first)
        #expect(backend.orientationReads == reads)
        #expect(ScreenshotMaskTests.pixel(next.image, 10, 10) == VideoMaskTests.black)
    }

    @Test("a frame the writer refused is taken again although the screen has not changed")
    func retake() async throws {
        let screen = UIScreenInfo(width: 390, height: 844, scale: 3, rotation: .portrait)
        let backend = SurfaceFakeBackend(surface: FakeSurface(width: 39, height: 84), screen: screen)
        let source = VideoFrameSource(backend: backend, device: Self.device, scale: 1, regions: [])

        _ = try await source.start()
        #expect(try await source.next().unchanged)
        source.retakeNext()
        #expect(try await !source.next().unchanged)
    }

    @Test("a still screen records its first frame and one at the end, so the clip runs the whole time and every frame is in the MP4")
    func stillScreenRecording() async throws {
        let folder = try VideoRecordingFileTests.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let target = folder.appendingPathComponent("clip.mp4")
        let screen = UIScreenInfo(width: 39, height: 84, scale: 2, rotation: .portrait)
        let backend = SurfaceFakeBackend(surface: FakeSurface(width: 78, height: 168), screen: screen)

        let saved = try await RecordVideo.record(
            from: VideoFrameSource(backend: backend, device: Self.device, scale: 1, regions: []), to: (target, true),
            fps: 60, quality: 50, scale: 1, duration: 1, stop: RecordingStop(endNow: {})
        )

        #expect(saved.frames == 2)
        #expect(saved.seconds >= 0.9, "\(saved.seconds) s")
        #expect(try await VideoRecordingFileTests.samples(in: target) == saved.frames)
    }

    @Test("a moving screen writes a frame for each change, every one in the MP4")
    func movingScreenRecording() async throws {
        let folder = try VideoRecordingFileTests.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let target = folder.appendingPathComponent("clip.mp4")
        let screen = UIScreenInfo(width: 39, height: 84, scale: 2, rotation: .portrait)
        let backend = SurfaceFakeBackend(surface: FakeSurface(width: 78, height: 168), screen: screen)
        var shade: UInt8 = 0
        backend.onFrame = { surface in
            shade &+= 1
            surface.paint(0, 0, 4, 4, [shade, shade, shade, 255])
        }

        let saved = try await RecordVideo.record(
            from: VideoFrameSource(backend: backend, device: Self.device, scale: 1, regions: []), to: (target, true),
            fps: 60, quality: 50, scale: 1, duration: 1, stop: RecordingStop(endNow: {})
        )

        #expect(saved.frames > 10)
        #expect(try await VideoRecordingFileTests.samples(in: target) == saved.frames)
    }

    @Test("a simulator with two displays keeps the screenshot route and never attaches the framebuffer")
    func twoDisplays() async {
        var attached = false
        let route = await IOSBackend.videoRoute(twoDisplays: true) {
            attached = true
            return .unattached
        }

        guard case .screenshots(.twoDisplays) = route else { Issue.record("expected screenshots"); return }
        #expect(!attached)
        let refusal = IOSBackend.fullRateRefusal(fps: 60, device: Self.device, why: .twoDisplays)
        #expect(refusal.reason == .usage)
        #expect(refusal.userFacingDescription.contains("has two, so it takes up to 30"))
    }

    @Test("a framebuffer that cannot be attached falls back to screenshots, and above 30 fails with video_failed naming doctor")
    func unattached() async {
        let route = await IOSBackend.videoRoute(twoDisplays: false) { .unattached }

        guard case .screenshots(.unattached) = route else { Issue.record("expected screenshots"); return }
        let refusal = IOSBackend.fullRateRefusal(fps: 45, device: Self.device, why: .unattached)
        #expect(refusal.reason == .videoFailed)
        #expect(refusal.userFacingDescription.contains("offsider doctor --device \(Self.device.rawValue)"))
    }

    @Test("a framebuffer in another pixel format keeps screenshots, and above 30 is a usage error that sends no one to doctor")
    func otherFormat() async {
        let route = await IOSBackend.videoRoute(twoDisplays: false) { .otherFormat }

        guard case .screenshots(.otherFormat) = route else { Issue.record("expected screenshots"); return }
        let refusal = IOSBackend.fullRateRefusal(fps: 60, device: Self.device, why: .otherFormat)
        #expect(refusal.reason == .usage)
        #expect(!refusal.userFacingDescription.contains("doctor"))
    }
}

@Suite("Video frame rate limits")
@MainActor
struct VideoFrameRateTests {
    static let simulator = "00000000-0000-0000-0000-000000000001"

    @Test("up to 60 parses for an iOS simulator on every frame-taking command", arguments: [
        ["record-video", "--fps", "60"], ["stream-video", "--fps", "60"], ["stream-video", "--format", "raw", "--fps", "45"], ["stream-video", "--format", "ffmpeg", "--fps", "31"],
    ])
    func simulatorTakesSixty(_ arguments: [String]) throws {
        _ = try OffsiderCommand.parseAsRoot(arguments + ["--device", Self.simulator])
    }

    @Test("above 30 exits 64 naming the limit for an emulator, a phone and an iPhone, and above 60 for anything", arguments: [
        (["record-video", "--fps", "60", "--device", "emulator-5554"], "--fps 60 needs an iOS simulator; emulator-5554 takes up to 30."),
        (["stream-video", "--fps", "31", "--device", "emulator-5554"], "--fps 31 needs an iOS simulator; emulator-5554 takes up to 30."),
        (["record-video", "--fps", "60", "--device", "R00000000000"], "R00000000000 takes up to 30."),
        (["record-video", "--fps", "60", "--device", "00000000-0000000000000001"], "00000000-0000000000000001 takes up to 30."),
        (["record-video", "--fps", "61", "--device", simulator], "FPS must be between 1 and 30, or up to 60 on an iOS simulator"),
        (["stream-video", "--fps", "0", "--device", simulator], "FPS must be between 1 and 30, or up to 60 on an iOS simulator"),
    ])
    func limits(arguments: [String], message: String) {
        do {
            _ = try OffsiderCommand.parseAsRoot(arguments)
            Issue.record("expected a usage error for \(arguments)")
        } catch {
            #expect(OffsiderCommand.exitCode(for: error) == .validationFailure)
            #expect(OffsiderCommand.message(for: error).contains(message), "\(OffsiderCommand.message(for: error))")
        }
    }

    @Test("frames keep a fixed schedule, so a late wake does not push the next frame back, and a schedule fallen behind starts again from now")
    func pacing() {
        let start = ContinuousClock.now, frame = Duration.milliseconds(16)

        #expect(FramePacer.advance(start, by: frame, now: start + .milliseconds(3)) == start + frame)
        #expect(FramePacer.advance(start + frame, by: frame, now: start + .milliseconds(20)) == start + frame * 2)
        #expect(FramePacer.advance(start, by: frame, now: start + .milliseconds(50)) == start + .milliseconds(50))
    }

    @Test("30 or less parses for any device")
    func thirtyAnywhere() throws {
        _ = try OffsiderCommand.parseAsRoot(["record-video", "--fps", "30", "--device", "emulator-5554"])
    }

    @Test("a device that cannot read its frames in place is held to 30 with exit 64, after it is routed")
    func routedLimit() async throws {
        let backend = FakeDeviceBackend(trees: [])
        let error = await #expect(throws: CLIError.self) {
            try await VideoFrameRate.require(60, backend: backend, device: SurfaceFramesTests.device)
        }
        #expect(error?.reason == .usage)
        try await VideoFrameRate.require(30, backend: backend, device: SurfaceFramesTests.device)
    }
}
