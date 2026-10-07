import CoreGraphics
import Foundation
import ImageIO

/// A grid of per-tile hashes over decoded RGBA pixels, or with a tolerance per-block mean colours, so encoding and video noise do not count.
public struct ImageFingerprint: Equatable, Sendable {
    /// The side of the square pixel blocks averaged when there is a tolerance.
    public static let blockSize = 8
    /// The grid a caller gets when it names none.
    public static let defaultColumns = 16
    public static let defaultRows = 32

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
        columns: Int = defaultColumns,
        rows: Int = defaultRows,
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
            for tile in Self.tileSpans(
                width: width, height: height, columns: columns, rows: rows,
                excludingTop: firstRow, excludingBottom: height - endRow, excludingLeft: firstColumn, excludingRight: width - endColumn
            ) {
                if let base = rgba.baseAddress {
                    Self.forEachBlock(columns: tile.columns, rows: tile.rows) { columns, rows in
                        let mean = Self.blockMean(base, bytesPerRow: bytesPerRow, columns: columns, rows: rows)
                        blocks.append(mean.red)
                        blocks.append(mean.green)
                        blocks.append(mean.blue)
                    }
                }
                blockStarts.append(blocks.count)
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

    /// Each tile's pixels with the bands left out, tile row by tile row; a tile inside a band is empty.
    static func tileSpans(
        width: Int, height: Int, columns: Int, rows: Int, excludingTop: Int, excludingBottom: Int, excludingLeft: Int, excludingRight: Int
    ) -> [(columns: Range<Int>, rows: Range<Int>)] {
        let columns = max(1, min(columns, max(width, 1)))
        let rows = max(1, min(rows, max(height, 1)))
        let firstRow = max(0, min(excludingTop, height))
        let endRow = max(firstRow, height - max(0, excludingBottom))
        let firstColumn = max(0, min(excludingLeft, width))
        let endColumn = max(firstColumn, width - max(0, excludingRight))
        var spans: [(columns: Range<Int>, rows: Range<Int>)] = []
        spans.reserveCapacity(columns * rows)
        for tileRow in 0..<rows {
            let top = max((tileRow * height + rows - 1) / rows, firstRow)
            let bottom = max(top, min(((tileRow + 1) * height + rows - 1) / rows, endRow))
            for column in 0..<columns {
                let left = max(column * width / columns, firstColumn)
                let right = max(left, min((column + 1) * width / columns, endColumn))
                spans.append((left..<right, top..<bottom))
            }
        }
        return spans
    }

    /// Calls `body` with each `blockSize` square of the span, row by row; blocks at the span's right and bottom edges may be smaller.
    static func forEachBlock(columns: Range<Int>, rows: Range<Int>, _ body: (Range<Int>, Range<Int>) -> Void) {
        var top = rows.lowerBound
        while top < rows.upperBound {
            let bottom = min(top + blockSize, rows.upperBound)
            var left = columns.lowerBound
            while left < columns.upperBound {
                let right = min(left + blockSize, columns.upperBound)
                body(left..<right, top..<bottom)
                left = right
            }
            top = bottom
        }
    }

    /// The rounded mean red, green and blue of a block of RGBA pixels, two pixels per 8-byte word.
    static func blockMean(_ base: UnsafeRawPointer, bytesPerRow: Int, columns: Range<Int>, rows: Range<Int>) -> (red: UInt8, green: UInt8, blue: UInt8) {
        let lanes: UInt64 = 0x00FF_00FF_00FF_00FF
        let bytes = columns.count * 4
        var redBlue: UInt64 = 0
        var greenAlpha: UInt64 = 0
        var red = 0, green = 0, blue = 0
        var y = rows.lowerBound
        while y < rows.upperBound {
            let row = base + y * bytesPerRow + columns.lowerBound * 4
            y += 1
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
        let count = rows.count * columns.count
        return (UInt8((red + count / 2) / count), UInt8((green + count / 2) / count), UInt8((blue + count / 2) / count))
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
        pngData: Data, columns: Int = defaultColumns, rows: Int = defaultRows, excludingTopPixels: Int = 0, excludingBottomPixels: Int = 0,
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
        columns: Int = defaultColumns,
        rows: Int = defaultRows,
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

    /// The tiles any of `rects` touches, in this fingerprint's pixels, for leaving pixels the tree explains out of a comparison.
    public func tiles(intersecting rects: [PixelRect]) -> Set<Int> {
        guard width > 0, height > 0 else { return [] }
        var touched = Set<Int>()
        for rect in rects where rect.width > 0 && rect.height > 0 {
            let left = max(0, rect.x), right = min(width, rect.x + rect.width)
            let top = max(0, rect.y), bottom = min(height, rect.y + rect.height)
            guard right > left, bottom > top else { continue }
            let firstRow = max(0, top * rows / height - 1), lastRow = min(rows - 1, (bottom - 1) * rows / height + 1)
            let firstColumn = max(0, left * columns / width - 1), lastColumn = min(columns - 1, (right - 1) * columns / width + 1)
            for row in firstRow...lastRow {
                for column in firstColumn...lastColumn where Self.overlaps(
                    column: column, row: row, left: left, right: right, top: top, bottom: bottom, width: width, height: height, columns: columns, rows: rows
                ) {
                    touched.insert(row * columns + column)
                }
            }
        }
        return touched
    }

    private static func overlaps(column: Int, row: Int, left: Int, right: Int, top: Int, bottom: Int, width: Int, height: Int, columns: Int, rows: Int) -> Bool {
        let tileLeft = column * width / columns, tileRight = (column + 1) * width / columns
        let tileTop = (row * height + rows - 1) / rows, tileBottom = ((row + 1) * height + rows - 1) / rows
        return tileLeft < right && left < tileRight && tileTop < bottom && top < tileBottom
    }

    /// Changed tiles over compared tiles; nil when the grids differ.
    public func changedFraction(comparedTo other: ImageFingerprint) -> Double? {
        guard let changed = changedTiles(comparedTo: other) else { return nil }
        let compared = min(comparedTileCount, other.comparedTileCount)
        return compared == 0 ? 0 : Double(changed.count) / Double(compared)
    }
}

public enum ScreenChange {
    /// The share of compared tiles that counts as motion: a transition, a video or a carousel moves more, a ticking label, a caret or a small spinner less.
    public static let movingFraction = 0.1

    /// Tiles in `ignoring` never count; changed tiles still moving after the input count only when still across the before-shots and over `movingFraction`.
    public static func detect(before: [ImageFingerprint], after: [ImageFingerprint], ignoring: Set<Int> = []) -> Bool {
        guard let reference = before.last, let last = after.last else { return false }
        guard let changed = reference.changedTiles(comparedTo: last)?.subtracting(ignoring) else { return true }
        if !changed.isSubset(of: movingTiles(after) ?? []) { return true }
        guard before.count > 1, let movingBefore = movingTiles(before) else { return false }
        let compared = max(min(reference.comparedTileCount, last.comparedTileCount), 1)
        let started = Double(changed.subtracting(movingBefore).count) / Double(compared)
        return ScreenCompare.outcome(changedFraction: started, threshold: movingFraction) == .changed
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
