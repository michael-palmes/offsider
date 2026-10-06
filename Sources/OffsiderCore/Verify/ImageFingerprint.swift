import CoreGraphics
import Foundation
import ImageIO

/// A grid of per-tile hashes over decoded RGBA pixels, or with a tolerance per-block mean colours, so encoding and video noise do not count.
public struct ImageFingerprint: Equatable, Sendable {
    /// The side of the square pixel blocks averaged when there is a tolerance.
    public static let blockSize = 8

    public let width: Int
    public let height: Int
    public let columns: Int
    public let rows: Int
    /// Tiles with at least one pixel outside the excluded bands.
    public let comparedTileCount: Int
    /// How far a block's mean red, green or blue may move before its tile counts as changed; 0 compares pixels exactly.
    public let tolerance: Int
    private let tiles: [UInt64]
    /// With a tolerance: every tile's block means, back to back, tile `i` at `blockStarts[i]..<blockStarts[i + 1]`.
    private let blocks: [UInt8]
    private let blockStarts: [Int]

    public init(
        rgba: UnsafeRawBufferPointer,
        width: Int,
        height: Int,
        bytesPerRow: Int,
        columns: Int = 16,
        rows: Int = 32,
        excludingTopPixels: Int = 0,
        excludingBottomPixels: Int = 0,
        excludingLeftPixels: Int = 0,
        excludingRightPixels: Int = 0,
        tolerance: Int = 0
    ) {
        let columns = max(1, min(columns, max(width, 1)))
        let rows = max(1, min(rows, max(height, 1)))
        self.width = width
        self.height = height
        self.columns = columns
        self.rows = rows
        self.tolerance = max(0, tolerance)

        let columnStarts = (0...columns).map { $0 * width / columns }
        let firstRow = max(0, min(excludingTopPixels, height))
        let endRow = max(firstRow, height - max(0, excludingBottomPixels))
        let firstColumn = max(0, min(excludingLeftPixels, width))
        let endColumn = max(firstColumn, width - max(0, excludingRightPixels))
        let spans = (0..<columns).map { (max(columnStarts[$0], firstColumn), min(columnStarts[$0 + 1], endColumn)) }
        let comparedColumns = spans.filter { $0.1 > $0.0 }.count
        comparedTileCount = endRow > firstRow ? ((endRow - 1) * rows / height - firstRow * rows / height + 1) * comparedColumns : 0
        guard self.tolerance == 0 else {
            tiles = []
            var blocks: [UInt8] = []
            blocks.reserveCapacity(3 * (width / Self.blockSize + columns) * (height / Self.blockSize + rows))
            var blockStarts = [0]
            blockStarts.reserveCapacity(columns * rows + 1)
            for tileRow in 0..<rows {
                let top = max((tileRow * height + rows - 1) / rows, firstRow)
                let bottom = min(((tileRow + 1) * height + rows - 1) / rows, endRow)
                for column in 0..<columns {
                    if let base = rgba.baseAddress, bottom > top, spans[column].1 > spans[column].0 {
                        Self.appendBlockMeans(
                            to: &blocks, base, bytesPerRow: bytesPerRow, columns: spans[column].0..<spans[column].1, rows: top..<bottom
                        )
                    }
                    blockStarts.append(blocks.count)
                }
            }
            self.blocks = blocks
            self.blockStarts = blockStarts
            return
        }
        blocks = []
        blockStarts = []
        var tiles = [UInt64](repeating: 0xcbf2_9ce4_8422_2325, count: columns * rows)
        guard let base = rgba.baseAddress, width > 0 else {
            self.tiles = tiles
            return
        }
        for y in firstRow..<endRow {
            let tileRow = y * rows / height
            let rowStart = base + y * bytesPerRow
            for column in 0..<columns where spans[column].1 > spans[column].0 {
                let start = rowStart + spans[column].0 * 4
                let count = (spans[column].1 - spans[column].0) * 4
                tiles[tileRow * columns + column] = Self.hash(start, count: count, seed: tiles[tileRow * columns + column])
            }
        }
        self.tiles = tiles
    }

    /// Appends the rounded mean red, green and blue of each `blockSize` square in the span, row by row, two pixels per 8-byte word.
    private static func appendBlockMeans(to means: inout [UInt8], _ base: UnsafeRawPointer, bytesPerRow: Int, columns: Range<Int>, rows: Range<Int>) {
        let lanes: UInt64 = 0x00FF_00FF_00FF_00FF
        var top = rows.lowerBound
        while top < rows.upperBound {
            let bottom = min(top + blockSize, rows.upperBound)
            var left = columns.lowerBound
            while left < columns.upperBound {
                let right = min(left + blockSize, columns.upperBound)
                let bytes = (right - left) * 4
                var redBlue: UInt64 = 0
                var greenAlpha: UInt64 = 0
                var red = 0, green = 0, blue = 0
                for y in top..<bottom {
                    let row = base + y * bytesPerRow + left * 4
                    var offset = 0
                    while offset + 8 <= bytes {
                        let word = UInt64(littleEndian: row.loadUnaligned(fromByteOffset: offset, as: UInt64.self))
                        redBlue &+= word & lanes
                        greenAlpha &+= (word >> 8) & lanes
                        offset += 8
                    }
                    if offset < bytes {
                        red += Int(row.load(fromByteOffset: offset, as: UInt8.self))
                        green += Int(row.load(fromByteOffset: offset + 1, as: UInt8.self))
                        blue += Int(row.load(fromByteOffset: offset + 2, as: UInt8.self))
                    }
                }
                red += Int(redBlue & 0xFFFF) + Int((redBlue >> 32) & 0xFFFF)
                blue += Int((redBlue >> 16) & 0xFFFF) + Int((redBlue >> 48) & 0xFFFF)
                green += Int(greenAlpha & 0xFFFF) + Int((greenAlpha >> 32) & 0xFFFF)
                let count = (bottom - top) * (right - left)
                means.append(UInt8((red + count / 2) / count))
                means.append(UInt8((green + count / 2) / count))
                means.append(UInt8((blue + count / 2) / count))
                left = right
            }
            top = bottom
        }
    }

    /// FNV-1a over 8-byte words, so a full-resolution screenshot hashes quickly even in debug builds.
    private static func hash(_ start: UnsafeRawPointer, count: Int, seed: UInt64) -> UInt64 {
        var hash = seed
        var offset = 0
        while offset + 8 <= count {
            hash ^= start.loadUnaligned(fromByteOffset: offset, as: UInt64.self)
            hash = hash &* 0x100_0000_01b3
            offset += 8
        }
        while offset < count {
            hash ^= UInt64(start.load(fromByteOffset: offset, as: UInt8.self))
            hash = hash &* 0x100_0000_01b3
            offset += 1
        }
        return hash
    }

    public init?(
        pngData: Data, columns: Int = 16, rows: Int = 32, excludingTopPixels: Int = 0, excludingBottomPixels: Int = 0,
        excludingLeftPixels: Int = 0, excludingRightPixels: Int = 0, tolerance: Int = 0
    ) {
        guard let image = try? ScreenImage.decode(pngData) else { return nil }
        self.init(
            image: image, columns: columns, rows: rows, excludingTopPixels: excludingTopPixels, excludingBottomPixels: excludingBottomPixels,
            excludingLeftPixels: excludingLeftPixels, excludingRightPixels: excludingRightPixels, tolerance: tolerance
        )
    }

    /// With `region`, only that part of the image is fingerprinted, and the bands count from its top and bottom.
    public init?(
        image: CGImage,
        region: PixelRect? = nil,
        columns: Int = 16,
        rows: Int = 32,
        excludingTopPixels: Int = 0,
        excludingBottomPixels: Int = 0,
        excludingLeftPixels: Int = 0,
        excludingRightPixels: Int = 0,
        tolerance: Int = 0
    ) {
        guard let image = try? region.map({ try ScreenImage.cropped(image, to: $0) }) ?? image,
              let colourSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
            return nil
        }
        let width = image.width
        let height = image.height
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = ScreenImage.context(width: width, height: height, colourSpace: colourSpace, data: buffer.baseAddress) else {
                return false
            }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        self = pixels.withUnsafeBytes { buffer in
            ImageFingerprint(
                rgba: buffer,
                width: width,
                height: height,
                bytesPerRow: bytesPerRow,
                columns: columns,
                rows: rows,
                excludingTopPixels: excludingTopPixels,
                excludingBottomPixels: excludingBottomPixels,
                excludingLeftPixels: excludingLeftPixels,
                excludingRightPixels: excludingRightPixels,
                tolerance: tolerance
            )
        }
    }

    /// Returns nil when the images cannot be compared tile for tile, which callers treat as a change.
    public func changedTiles(comparedTo other: ImageFingerprint) -> Set<Int>? {
        guard width == other.width, height == other.height, columns == other.columns, rows == other.rows, tolerance == other.tolerance else {
            return nil
        }
        guard tolerance > 0 else { return Set(tiles.indices.filter { tiles[$0] != other.tiles[$0] }) }
        let tolerance = tolerance
        return blocks.withUnsafeBufferPointer { mine in
            other.blocks.withUnsafeBufferPointer { theirs in
                var changed = Set<Int>()
                for tile in 0..<(columns * rows) {
                    let start = blockStarts[tile]
                    let end = blockStarts[tile + 1]
                    let offset = other.blockStarts[tile] - start
                    guard other.blockStarts[tile + 1] - offset == end else {
                        changed.insert(tile)
                        continue
                    }
                    var index = start
                    while index < end {
                        let difference = Int(mine[index]) - Int(theirs[index + offset])
                        if difference > tolerance || difference < -tolerance {
                            changed.insert(tile)
                            break
                        }
                        index += 1
                    }
                }
                return changed
            }
        }
    }

    /// Changed tiles over compared tiles; nil when the grids differ.
    public func changedFraction(comparedTo other: ImageFingerprint) -> Double? {
        guard let changed = changedTiles(comparedTo: other) else { return nil }
        let compared = min(comparedTileCount, other.comparedTileCount)
        return compared == 0 ? 0 : Double(changed.count) / Double(compared)
    }
}

public enum ScreenChange {
    /// The most tiles a blinking caret covers (two rows by two columns), which both before-shots can catch in one phase.
    static let caretTiles = 4

    /// Changed tiles still moving after the input (a caret, a spinner) count only when they were still across the before-shots and outnumber a caret's.
    public static func detect(before: [ImageFingerprint], after: [ImageFingerprint]) -> Bool {
        guard let reference = before.last, let last = after.last else { return false }
        guard let changed = reference.changedTiles(comparedTo: last) else { return true }
        if !changed.isSubset(of: movingTiles(after) ?? []) { return true }
        guard before.count > 1, let movingBefore = movingTiles(before) else { return false }
        return changed.subtracting(movingBefore).count > caretTiles
    }

    /// Tiles that differ between any two of `shots`; nil when two cannot be compared tile for tile.
    private static func movingTiles(_ shots: [ImageFingerprint]) -> Set<Int>? {
        var moving = Set<Int>()
        for (index, shot) in shots.enumerated() {
            for other in shots[(index + 1)...] {
                guard let changed = shot.changedTiles(comparedTo: other) else { return nil }
                moving.formUnion(changed)
            }
        }
        return moving
    }
}
