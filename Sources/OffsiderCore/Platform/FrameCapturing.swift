import CoreGraphics
import Foundation

/// Optional capability: decoded, upright frames for video without a PNG round trip.
@MainActor
public protocol FrameCapturing: DeviceBackend {
    /// The frame at `scale` (0.1 to 1) of full size; the device scales when it can, so the command must not scale again.
    func captureFrame(for id: DeviceID, scale: Double) async throws -> CGImage
}

/// Optional capability: lets go of what this command's tree reads hold on a device, so another command can read it while this one only captures.
@MainActor
public protocol TreeReadReleasing: DeviceBackend {
    /// Stops this command's reader of `id`'s tree, such as Android's UiAutomation helper; a later tree read starts one again.
    func releaseTreeReads(on id: DeviceID) async
}
