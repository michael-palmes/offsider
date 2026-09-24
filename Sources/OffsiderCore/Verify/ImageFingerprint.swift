import CoreGraphics
import Foundation
import ImageIO

/// A grid of per-tile hashes over decoded RGBA pixels, so equal pixels match whatever the PNG encoding.
public struct ImageFingerprint: Equatable, Sendable {
    public let width: Int
    public let height: Int
    public let columns: Int
    public let rows: Int
    private let tiles: [UInt64]

    public init(
        rgba: UnsafeRawBufferPointer,
        width: Int,
        height: Int,
        bytesPerRow: Int,
        columns: Int = 16,
        rows: Int = 32,
        excludingTopPixels: Int = 0
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
        guard let base = rgba.baseAddress, width > 0 else {
            self.tiles = tiles
            return
        }
        for y in firstRow..<height {
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

    public init?(pngData: Data, columns: Int = 16, rows: Int = 32, excludingTopPixels: Int = 0) {
        guard let source = CGImageSourceCreateWithData(pngData as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let colourSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
            return nil
        }
        let width = image.width
        let height = image.height
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: colourSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else {
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
                excludingTopPixels: excludingTopPixels
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
