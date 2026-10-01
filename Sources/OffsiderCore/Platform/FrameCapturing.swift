import CoreGraphics
import Foundation

/// Optional capability: decoded, upright frames for video without a PNG round trip.
@MainActor
public protocol FrameCapturing: DeviceBackend {
    /// The frame at `scale` (0.1 to 1) of full size; the device scales when it can, so the command must not scale again.
    func captureFrame(for id: DeviceID, scale: Double) async throws -> CGImage
}
