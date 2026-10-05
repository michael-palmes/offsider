import CoreGraphics
import Foundation

/// A pixel-exact comparison of two captures of the same size, with an image that shows where they differ.
public enum ScreenDiff {
    public struct Result {
        public let changedPixels: Int
        public let comparedPixels: Int
        /// The smallest rectangle holding every changed pixel; nil when none changed.
        public let bounds: PixelRect?
        /// The current capture faded 75 % to white, changed pixels opaque magenta, excluded bands 50 % grey.
        public let image: CGImage
    }

    static let magenta = rgba(255, 0, 255, 255)
    static let grey = rgba(128, 128, 128, 255)

    /// Both images are drawn into sRGB first; a pixel changed when any of its RGBA bytes differs. Rows in the excluded bands are not counted.
    public static func compare(baseline: CGImage, current: CGImage, excludingTop top: Int = 0, excludingBottom bottom: Int = 0) throws -> Result {
        let width = current.width
        let height = current.height
        guard baseline.width == width, baseline.height == height else {
            throw ImageFailure(detail: "the baseline is \(baseline.width) x \(baseline.height) px but the capture is \(width) x \(height) px")
        }
        let sRGB = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let before = try ScreenImage.pixels(of: baseline, colourSpace: sRGB)
        let after = try ScreenImage.pixels(of: current, colourSpace: sRGB)
        let firstRow = min(max(top, 0), height)
        let endRow = max(firstRow, height - max(bottom, 0))

        var output = [UInt32](repeating: grey, count: width * height)
        var changed = 0
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in firstRow..<endRow {
            let row = y * width
            for x in 0..<width {
                let index = row + x
                if before[index] != after[index] {
                    output[index] = magenta
                    changed += 1
                    minX = min(minX, x)
                    maxX = max(maxX, x)
                    minY = min(minY, y)
                    maxY = max(maxY, y)
                } else {
                    output[index] = faded(after[index])
                }
            }
        }
        let bounds = changed == 0 ? nil : PixelRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
        let image = try ScreenImage.makeImage(output, width: width, height: height, colourSpace: sRGB)
        return Result(changedPixels: changed, comparedPixels: width * (endRow - firstRow), bounds: bounds, image: image)
    }

    /// Each byte three quarters of the way to 255.
    static func faded(_ pixel: UInt32) -> UInt32 {
        var result: UInt32 = 0
        for shift in stride(from: 0, to: 32, by: 8) {
            let byte = (pixel >> UInt32(shift)) & 0xFF
            result |= ((byte + 3 * 255) / 4) << UInt32(shift)
        }
        return result
    }

    /// A pixel whose bytes in memory are red, green, blue, alpha.
    static func rgba(_ red: UInt32, _ green: UInt32, _ blue: UInt32, _ alpha: UInt32) -> UInt32 {
        (red | green << 8 | blue << 16 | alpha << 24).littleEndian
    }
}
