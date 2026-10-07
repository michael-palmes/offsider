import CoreGraphics
import Foundation

/// Withheld rather than guessed: an element Offsider was asked to mask but cannot place must not reach an image.
public struct MaskUnproven: LocalizedError, CustomStringConvertible, Equatable, Sendable {
    public let detail: String

    public init(detail: String) {
        self.detail = detail
    }

    public var errorDescription: String? { description }
    public var description: String {
        "\(detail), so it cannot be masked; the screenshot was withheld and no file was written. Retry when the screen is still, or capture without that mask."
    }
}

/// Frames in points to whole-pixel rectangles to paint over.
public enum SecureMask {
    /// Rounded outward (floor the origin, ceil the far edge) and clamped to the image; zero-area frames are skipped.
    /// `subject` names what a frame belongs to, such as "A secure field", for the error when one cannot be placed.
    public static func pixelRects(frames: [UIFrame?], subject: String = "A secure field", pixelsPerPoint: Double?, imageWidth: Int, imageHeight: Int) throws -> [CGRect] {
        guard !frames.isEmpty else { return [] }
        guard let pixelsPerPoint, pixelsPerPoint > 0 else {
            throw MaskUnproven(detail: "\(subject) is on screen but the capture could not be mapped to points")
        }
        return try frames.compactMap { frame -> CGRect? in
            guard let frame, ![frame.x, frame.y, frame.width, frame.height].contains(where: \.isNaN) else {
                throw MaskUnproven(detail: "\(subject) on screen has no frame")
            }
            guard frame.width > 0, frame.height > 0 else { return nil }
            let left = ScreenGeometry.pixel(frame.x, pixelsPerPoint: pixelsPerPoint, .down, limit: imageWidth)
            let top = ScreenGeometry.pixel(frame.y, pixelsPerPoint: pixelsPerPoint, .down, limit: imageHeight)
            let right = ScreenGeometry.pixel(frame.x + frame.width, pixelsPerPoint: pixelsPerPoint, .up, limit: imageWidth)
            let bottom = ScreenGeometry.pixel(frame.y + frame.height, pixelsPerPoint: pixelsPerPoint, .up, limit: imageHeight)
            guard right > left, bottom > top else { return nil }
            return CGRect(x: left, y: top, width: right - left, height: bottom - top)
        }
    }
}
