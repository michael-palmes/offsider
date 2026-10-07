import CoreGraphics
import Foundation

/// A comparison of two captures of the same size, pixel by pixel or block by block, with an image that shows where they differ.
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

    /// Both images are drawn into sRGB first; a pixel changed when any RGBA byte differs, or with a tolerance when its fingerprint block's mean moved by more.
    public static func compare(
        baseline: CGImage, current: CGImage, excludingTop top: Int = 0, excludingBottom bottom: Int = 0, tolerance: Int = 0
    ) throws -> Result {
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
        before.withUnsafeBufferPointer { beforePixels in
            after.withUnsafeBufferPointer { afterPixels in
                output.withUnsafeMutableBufferPointer { outputPixels in
                    guard let old = beforePixels.baseAddress, let new = afterPixels.baseAddress, let marked = outputPixels.baseAddress else { return }
                    guard tolerance > 0 else {
                        var index = firstRow * width
                        while index < endRow * width {
                            if old[index] != new[index] {
                                marked[index] = magenta
                                changed += 1
                                minX = min(minX, index % width)
                                maxX = max(maxX, index % width)
                                minY = min(minY, index / width)
                                maxY = max(maxY, index / width)
                            } else {
                                marked[index] = faded(new[index])
                            }
                            index += 1
                        }
                        return
                    }
                    let tiles = ImageFingerprint.tileSpans(
                        width: width, height: height, columns: ImageFingerprint.defaultColumns, rows: ImageFingerprint.defaultRows,
                        excludingTop: firstRow, excludingBottom: height - endRow, excludingLeft: 0, excludingRight: 0
                    )
                    for tile in tiles {
                        ImageFingerprint.forEachBlock(columns: tile.columns, rows: tile.rows) { columns, rows in
                            let was = ImageFingerprint.blockMean(UnsafeRawPointer(old), bytesPerRow: width * 4, columns: columns, rows: rows)
                            let now = ImageFingerprint.blockMean(UnsafeRawPointer(new), bytesPerRow: width * 4, columns: columns, rows: rows)
                            let moved = differs(was.red, now.red, by: tolerance) || differs(was.green, now.green, by: tolerance)
                                || differs(was.blue, now.blue, by: tolerance)
                            let blockWidth = columns.count
                            var rowStart = rows.lowerBound * width + columns.lowerBound
                            let end = rows.upperBound * width
                            while rowStart < end {
                                if moved {
                                    (marked + rowStart).update(repeating: magenta, count: blockWidth)
                                } else {
                                    var index = rowStart
                                    while index < rowStart + blockWidth {
                                        marked[index] = faded(new[index])
                                        index += 1
                                    }
                                }
                                rowStart += width
                            }
                            guard moved else { return }
                            changed += blockWidth * rows.count
                            minX = min(minX, columns.lowerBound)
                            maxX = max(maxX, columns.upperBound - 1)
                            minY = min(minY, rows.lowerBound)
                            maxY = max(maxY, rows.upperBound - 1)
                        }
                    }
                }
            }
        }
        let bounds = changed == 0 ? nil : PixelRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
        let image = try ScreenImage.makeImage(output, width: width, height: height, colourSpace: sRGB)
        return Result(changedPixels: changed, comparedPixels: width * (endRow - firstRow), bounds: bounds, image: image)
    }

    /// Each byte three quarters of the way to 255, two bytes per 16-bit lane so it stays fast in debug builds.
    static func faded(_ pixel: UInt32) -> UInt32 {
        let lanes: UInt32 = 0x00FF_00FF
        let even = (((pixel & lanes) &+ 0x02FD_02FD) >> 2) & lanes
        let odd = ((((pixel >> 8) & lanes) &+ 0x02FD_02FD) >> 2) & lanes
        return even | odd << 8
    }

    /// True when two block means are more than `tolerance` apart.
    private static func differs(_ old: UInt8, _ new: UInt8, by tolerance: Int) -> Bool {
        let difference = Int(old) - Int(new)
        return difference > tolerance || difference < -tolerance
    }

    /// A pixel whose bytes in memory are red, green, blue, alpha.
    static func rgba(_ red: UInt32, _ green: UInt32, _ blue: UInt32, _ alpha: UInt32) -> UInt32 {
        (red | green << 8 | blue << 16 | alpha << 24).littleEndian
    }
}
