import CoreGraphics
import CoreVideo
import FBSimulatorControl
import Foundation
import IOSurface
import OffsiderCore

extension IOSurface: FrameSurface {
    public func withLockedPixels<T>(_ body: (UnsafeRawBufferPointer, Int, Int, Int) throws -> T) throws -> T? {
        guard bytesPerElement == 4, lock(options: .readOnly, seed: nil) == kIOReturnSuccess else { return nil }
        defer { unlock(options: .readOnly, seed: nil) }
        return try body(UnsafeRawBufferPointer(start: baseAddress, count: allocationSize), width, height, bytesPerRow)
    }
}

/// The framebuffer one recording reads, held from its first frame to its end.
@MainActor
final class SimulatorVideoSurface {
    enum Attachment {
        case attached(SimulatorVideoSurface)
        case unattached
        /// The surface is not 8-bit BGRA, which the copy reads.
        case otherFormat
    }

    private let framebuffer: FBFramebuffer
    private let holder: FramebufferSurfaceHolder
    private var frames: SurfaceFrames?
    private var lastSurface: ObjectIdentifier?

    private init(framebuffer: FBFramebuffer, holder: FramebufferSurfaceHolder) {
        self.framebuffer = framebuffer
        self.holder = holder
    }

    static func attach(to framebuffer: FBFramebuffer) -> Attachment {
        let holder = FramebufferSurfaceHolder()
        guard let surface = framebuffer.attach(holder, on: holder.queue) else {
            framebuffer.detach(holder)
            return .unattached
        }
        guard surface.pixelFormat == kCVPixelFormatType_32BGRA else {
            framebuffer.detach(holder)
            return .otherFormat
        }
        holder.didChange(surface)
        return .attached(SimulatorVideoSurface(framebuffer: framebuffer, holder: holder))
    }

    func next(scale: Double, quarterTurns: Int, skipUnchanged: Bool) throws -> SurfaceFrames.Frame {
        guard let surface = holder.surface else { throw ImageFailure(detail: "the simulator's display is not ready") }
        let frames = self.frames.flatMap { $0.scale == scale && $0.quarterTurns == ((quarterTurns % 4) + 4) % 4 ? $0 : nil }
            ?? SurfaceFrames(quarterTurns: quarterTurns, scale: scale)
        if frames !== self.frames || lastSurface != ObjectIdentifier(surface) {
            lastSurface = ObjectIdentifier(surface)
            frames.reset()
        }
        self.frames = frames
        return try frames.next(from: surface, skipUnchanged: skipUnchanged)
    }

    func close() {
        framebuffer.detach(holder)
        holder.didChange(nil)
    }
}

/// A simulator's video frames: read from its framebuffer, or screenshots when that cannot be used.
enum SimulatorVideoRoute {
    case surface(SimulatorVideoSurface)
    case screenshots(why: ScreenshotRouteReason)
}

enum ScreenshotRouteReason: Equatable {
    case twoDisplays
    case unattached
    case otherFormat
}

/// Each recording's route and the screen its frames are turned by, per device; set only through its methods.
@MainActor
final class SimulatorVideoState {
    private(set) var routes: [String: SimulatorVideoRoute] = [:]
    private(set) var screens: [String: UIScreenInfo] = [:]

    func set(_ route: SimulatorVideoRoute, for id: DeviceID) {
        routes[id.rawValue] = route
    }

    func set(_ screen: UIScreenInfo, for id: DeviceID) {
        screens[id.rawValue] = screen
    }

    func end(_ id: DeviceID) {
        screens[id.rawValue] = nil
        if case .surface(let surface) = routes.removeValue(forKey: id.rawValue) { surface.close() }
    }
}

extension IOSBackend: FrameCapturing, FullRateFrameCapturing {
    func captureFrame(for id: DeviceID, scale: Double) async throws -> CGImage {
        guard let image = try await changedFrame(for: id, scale: scale, skipUnchanged: false) else {
            throw ImageFailure(detail: "the simulator gave no frame")
        }
        return image
    }

    func changedFrame(for id: DeviceID, scale: Double, skipUnchanged: Bool) async throws -> CGImage? {
        let route = try await videoRoute(for: id)
        let screen = videoState.screens[id.rawValue]
        switch route {
        case .surface(let surface):
            let turns = screen.map(Self.quarterTurns) ?? 0
            let frame = try Timings.measure("capture") { try surface.next(scale: scale, quarterTurns: turns, skipUnchanged: skipUnchanged) }
            guard case .image(let image) = frame else { return nil }
            return image
        case .screenshots:
            let upright = try ScreenCapture.make(png: try await screenshotPNG(for: id), platform: .ios, screen: screen).image
            let width = SurfaceFrames.scaledSide(upright.width, by: scale), height = SurfaceFrames.scaledSide(upright.height, by: scale)
            return try ScreenImage.scaled(upright, width: width, height: height)
        }
    }

    func useScreen(_ screen: UIScreenInfo?, for id: DeviceID) {
        if let screen { videoState.set(screen, for: id) }
    }

    func requireFullRate(fps: Int, for id: DeviceID) async throws {
        guard case .screenshots(let why) = try await videoRoute(for: id) else { return }
        throw Self.fullRateRefusal(fps: fps, device: id, why: why)
    }

    static func fullRateRefusal(fps: Int, device id: DeviceID, why: ScreenshotRouteReason) -> CLIError {
        switch why {
        case .twoDisplays:
            return CLIError(
                errorDescription: "--fps \(fps) needs a simulator with one display; \(id.rawValue) has two, so it takes up to \(VideoFrameRate.standardLimit).",
                reason: .usage
            )
        case .otherFormat:
            return CLIError(
                errorDescription: "--fps \(fps) needs a display Offsider can read in place; \(id.rawValue)'s is in another pixel format, so it takes up to \(VideoFrameRate.standardLimit).",
                reason: .usage
            )
        case .unattached:
            return CLIError(
                errorDescription: "--fps \(fps) needs the simulator's display, which Offsider could not read, so \(id.rawValue) takes up to \(VideoFrameRate.standardLimit). "
                    + "Run `offsider doctor --device \(id.rawValue)`, or pass --fps \(VideoFrameRate.standardLimit) or less.",
                reason: .videoFailed,
                hint: "offsider doctor --device \(id.rawValue)"
            )
        }
    }

    func endFrames(for id: DeviceID) {
        videoState.end(id)
    }

    /// The turns that make idb's native framebuffer upright for `screen`, as `ScreenCapture.make` turns a screenshot.
    nonisolated static func quarterTurns(for screen: UIScreenInfo) -> Int {
        screen.captureArrivesUpright ? 0 : (screen.rotation?.uprightQuarterTurnsCounterclockwise ?? 0)
    }

    private func videoRoute(for id: DeviceID) async throws -> SimulatorVideoRoute {
        if let route = videoState.routes[id.rawValue] { return route }
        let simulator = try await simulator(for: id)
        if videoState.screens[id.rawValue] == nil, let screen = try? await screenInfo(for: id) {
            videoState.set(screen, for: id)
        }
        let route = await Self.videoRoute(twoDisplays: displayCatalog.isFoldable(simulator)) {
            guard let framebuffer = try? await Timings.measure("framebuffer", { try await bridgeFBFuture(simulator.connectToFramebuffer()) }) else {
                return .unattached
            }
            return SimulatorVideoSurface.attach(to: framebuffer)
        }
        switch route {
        case .screenshots(.unattached):
            Console.current.line(
                "Note: Offsider could not read \(id.rawValue)'s display directly, so this video is made of screenshots, at most \(VideoFrameRate.standardLimit) a second.",
                person: .note("Video falls back to screenshots, at most \(VideoFrameRate.standardLimit) a second")
            )
        case .screenshots(.otherFormat):
            Console.current.line(
                "Note: \(id.rawValue)'s display is in a pixel format Offsider does not read in place, so this video is made of screenshots, at most \(VideoFrameRate.standardLimit) a second.",
                person: .note("Video falls back to screenshots, at most \(VideoFrameRate.standardLimit) a second")
            )
        default:
            break
        }
        videoState.set(route, for: id)
        return route
    }

    /// idb's surface is the first framebuffer it finds, which on a simulator with two displays can be the dark one, so those keep screenshots.
    static func videoRoute(twoDisplays: Bool, attach: () async -> SimulatorVideoSurface.Attachment) async -> SimulatorVideoRoute {
        guard !twoDisplays else { return .screenshots(why: .twoDisplays) }
        switch await attach() {
        case .attached(let surface): return .surface(surface)
        case .unattached: return .screenshots(why: .unattached)
        case .otherFormat: return .screenshots(why: .otherFormat)
        }
    }
}
