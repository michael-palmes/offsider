import ArgumentParser
import CoreGraphics
import Foundation
import OffsiderCore

/// A device whose frames can be read in place: fast enough for 60 a second, and able to tell a frame equal to the last.
@MainActor
protocol FullRateFrameCapturing: FrameCapturing {
    /// Nil when `skipUnchanged` and the screen has not changed since the last frame returned.
    func changedFrame(for id: DeviceID, scale: Double, skipUnchanged: Bool) async throws -> CGImage?
    /// The screen the frames are turned by, read where the frame source reads it; nil keeps the device's own read.
    func useScreen(_ screen: UIScreenInfo?, for id: DeviceID)
    /// Throws when this device cannot take `fps` above the standard limit.
    func requireFullRate(fps: Int, for id: DeviceID) async throws
    /// Lets go of what the frames hold.
    func endFrames(for id: DeviceID)
}

/// `--fps` for `record-video` and `stream-video`: up to 60 on an iOS simulator with one display, else 30.
enum VideoFrameRate {
    static let standardLimit = 30
    static let fullLimit = 60
    static let help: ArgumentHelp = "Frames per second (1-30, or up to 60 on an iOS simulator)"

    /// Before routing, so a refused rate starts nothing.
    static func validate(_ fps: Int, device: String) throws {
        guard (1...fullLimit).contains(fps) else {
            throw ValidationError("FPS must be between 1 and \(standardLimit), or up to \(fullLimit) on an iOS simulator")
        }
        guard fps > standardLimit else { return }
        guard case .iosSimulator = DeviceIDClassifier.classify(device) else {
            throw ValidationError(limitMessage(fps: fps, device: device))
        }
    }

    /// After the device is booted and before the first frame.
    @MainActor
    static func require(_ fps: Int, backend: any DeviceBackend, device: DeviceID) async throws {
        guard fps > standardLimit else { return }
        guard let fullRate = backend as? any FullRateFrameCapturing else {
            throw CLIError(errorDescription: limitMessage(fps: fps, device: device.rawValue), reason: .usage)
        }
        try await fullRate.requireFullRate(fps: fps, for: device)
    }

    static func limitMessage(fps: Int, device: String) -> String {
        "--fps \(fps) needs an iOS simulator; \(device) takes up to \(standardLimit)."
    }
}

/// Frames on a fixed schedule, so a late wake costs that frame's slack rather than the rate; a schedule fallen behind starts again from now.
struct FramePacer {
    let interval: Duration
    private var next: ContinuousClock.Instant

    init(fps: Int, from start: ContinuousClock.Instant = ContinuousClock.now) {
        interval = .seconds(1.0 / Double(max(1, fps)))
        next = start
    }

    /// Sleeps until the next frame is due, or `limit` if sooner.
    mutating func wait(until limit: ContinuousClock.Instant? = nil) async throws {
        let now = ContinuousClock.now
        next = Self.advance(next, by: interval, now: now)
        let due = limit.map { min(next, $0) } ?? next
        if due > now { try await Task.sleep(until: due, tolerance: .zero, clock: .continuous) }
    }

    static func advance(_ next: ContinuousClock.Instant, by interval: Duration, now: ContinuousClock.Instant) -> ContinuousClock.Instant {
        max(next + interval, now)
    }
}
