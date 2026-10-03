import CoreGraphics
import Foundation
import ImageIO

/// A grid of per-tile hashes over decoded RGBA pixels, so equal pixels match whatever the PNG encoding.
public struct ImageFingerprint: Equatable, Sendable {
    public let width: Int
    public let height: Int
    public let columns: Int
    public let rows: Int
    /// Tiles with at least one pixel row outside the excluded bands.
    public let comparedTileCount: Int
    private let tiles: [UInt64]

    public init(
        rgba: UnsafeRawBufferPointer,
        width: Int,
        height: Int,
        bytesPerRow: Int,
        columns: Int = 16,
        rows: Int = 32,
        excludingTopPixels: Int = 0,
        excludingBottomPixels: Int = 0
    ) {
        let columns = max(1, min(columns, max(width, 1)))
        let rows = max(1, min(rows, max(height, 1)))
        self.width = width
        self.height = height
        self.columns = columns
        self.rows = rows

        var tiles = [UInt64](repeating: 0xcbf2_9ce4_8422_2325, count: columns * rows)
        let columnStarts = (0...columns).map { $0 * width / columns }
        let firstRow = max(0, min(excludingTopPixels, height))
        let endRow = max(firstRow, height - max(0, excludingBottomPixels))
        comparedTileCount = endRow > firstRow ? ((endRow - 1) * rows / height - firstRow * rows / height + 1) * columns : 0
        guard let base = rgba.baseAddress, width > 0 else {
            self.tiles = tiles
            return
        }
        for y in firstRow..<endRow {
            let tileRow = y * rows / height
            let rowStart = base + y * bytesPerRow
            for column in 0..<columns {
                let start = rowStart + columnStarts[column] * 4
                let count = (columnStarts[column + 1] - columnStarts[column]) * 4
                tiles[tileRow * columns + column] = Self.hash(start, count: count, seed: tiles[tileRow * columns + column])
            }
        }
        self.tiles = tiles
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

    public init?(pngData: Data, columns: Int = 16, rows: Int = 32, excludingTopPixels: Int = 0, excludingBottomPixels: Int = 0) {
        guard let image = try? ScreenImage.decode(pngData) else { return nil }
        self.init(image: image, columns: columns, rows: rows, excludingTopPixels: excludingTopPixels, excludingBottomPixels: excludingBottomPixels)
    }

    /// With `region`, only that part of the image is fingerprinted, and the bands count from its top and bottom.
    public init?(
        image: CGImage,
        region: PixelRect? = nil,
        columns: Int = 16,
        rows: Int = 32,
        excludingTopPixels: Int = 0,
        excludingBottomPixels: Int = 0
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
                excludingBottomPixels: excludingBottomPixels
            )
        }
    }

    /// Returns nil when the images cannot be compared tile for tile, which callers treat as a change.
    public func changedTiles(comparedTo other: ImageFingerprint) -> Set<Int>? {
        guard width == other.width, height == other.height, columns == other.columns, rows == other.rows else {
            return nil
        }
        return Set(tiles.indices.filter { tiles[$0] != other.tiles[$0] })
    }

    /// Changed tiles over compared tiles; nil when the grids differ.
    public func changedFraction(comparedTo other: ImageFingerprint) -> Double? {
        guard let changed = changedTiles(comparedTo: other) else { return nil }
        let compared = min(comparedTileCount, other.comparedTileCount)
        return compared == 0 ? 0 : Double(changed.count) / Double(compared)
    }
}

public enum ScreenChange {
    /// Tiles that differ among the after-shots (a blinking caret, a spinner) do not count.
    public static func detect(before: ImageFingerprint, after: [ImageFingerprint]) -> Bool {
        guard let last = after.last else { return false }
        guard let changed = before.changedTiles(comparedTo: last) else { return true }
        var volatile = Set<Int>()
        for (index, shot) in after.enumerated() {
            for other in after[(index + 1)...] {
                volatile.formUnion(shot.changedTiles(comparedTo: other) ?? [])
            }
        }
        return !changed.subtracting(volatile).isEmpty
    }
}
