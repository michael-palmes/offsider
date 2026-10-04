import CoreGraphics
import Foundation

/// Withheld rather than guessed: a secure field Offsider cannot place must not reach an image.
public struct MaskUnproven: LocalizedError, CustomStringConvertible, Equatable, Sendable {
    public let detail: String

    public init(detail: String) {
        self.detail = detail
    }

    public var errorDescription: String? { description }
    public var description: String {
        "\(detail), so it cannot be masked; the screenshot was withheld and no file was written. Retry when the screen is still, or capture without --mask-secure."
    }
}

/// Secure field frames in points to whole-pixel rectangles to paint over.
public enum SecureMask {
    /// Rounded outward (floor the origin, ceil the far edge) and clamped to the image; zero-area frames are skipped.
    public static func pixelRects(secureFrames: [UIFrame?], pixelsPerPoint: Double?, imageWidth: Int, imageHeight: Int) throws -> [CGRect] {
        guard !secureFrames.isEmpty else { return [] }
        guard let pixelsPerPoint, pixelsPerPoint > 0 else {
            throw MaskUnproven(detail: "A secure field is on screen but the capture could not be mapped to points")
        }
        return try secureFrames.compactMap { frame -> CGRect? in
            guard let frame else {
                throw MaskUnproven(detail: "A secure field on screen has no frame")
            }
            guard frame.width > 0, frame.height > 0 else { return nil }
            let left = max(0, Int((frame.x * pixelsPerPoint).rounded(.down)))
            let top = max(0, Int((frame.y * pixelsPerPoint).rounded(.down)))
            let right = min(imageWidth, Int(((frame.x + frame.width) * pixelsPerPoint).rounded(.up)))
            let bottom = min(imageHeight, Int(((frame.y + frame.height) * pixelsPerPoint).rounded(.up)))
            guard right > left, bottom > top else { return nil }
            return CGRect(x: left, y: top, width: right - left, height: bottom - top)
        }
    }
}
