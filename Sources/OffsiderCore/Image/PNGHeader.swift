import Foundation

/// What a PNG's first bytes say about it, read without decoding the image.
public enum PNGHeader {
    public static let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]

    /// The width and height in the IHDR chunk; nil for anything that does not start as a PNG does, or names a zero size.
    public static func size(of png: Data) -> (width: Int, height: Int)? {
        let bytes = [UInt8](png.prefix(24))
        guard bytes.count == 24, bytes.starts(with: signature), bytes[12..<16].elementsEqual("IHDR".utf8) else { return nil }
        let word = { (at: Int) in bytes[at..<(at + 4)].reduce(0) { $0 << 8 | Int($1) } }
        let width = word(16), height = word(20)
        guard width > 0, height > 0 else { return nil }
        return (width, height)
    }
}
