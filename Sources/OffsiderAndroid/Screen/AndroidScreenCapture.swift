import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Emulator frames made upright for the guest: a PNG passes through untouched when no crop or turn is needed.
enum AndroidScreenCapture {
    struct Pixels: Equatable, Sendable {
        let width: Int
        let height: Int
        /// Four bytes a pixel, rows top to bottom, no padding.
        let bytes: Data
    }

    struct ImageFailure: Error, Equatable {
        let detail: String
    }

    static func png(from frame: EmulatorFrame, guestRotation: Int) throws -> Data {
        let turns = PanelRotation.screenshotTurns(guestRotation: guestRotation, emulatorRotation: frame.emulatorRotation)
        if frame.format == .png, turns == 0, frame.folded == nil {
            return frame.bytes
        }
        return try encodePNG(upright(frame, guestRotation: guestRotation))
    }

    static func image(from frame: EmulatorFrame, guestRotation: Int) throws -> CGImage {
        try cgImage(upright(frame, guestRotation: guestRotation))
    }

    /// For `stream-video --format bgra`: the frame upright, blue and red swapped.
    static func bgra(from frame: EmulatorFrame, guestRotation: Int) throws -> Pixels {
        swapRedAndBlue(try upright(frame, guestRotation: guestRotation))
    }

    /// Cropped to the folded view while a foldable is folded, then turned to match the guest.
    static func upright(_ frame: EmulatorFrame, guestRotation: Int) throws -> Pixels {
        let turns = PanelRotation.screenshotTurns(guestRotation: guestRotation, emulatorRotation: frame.emulatorRotation)
        var pixels = try rgba(from: frame)
        if let folded = frame.folded {
            pixels = cropped(pixels, to: folded)
        }
        return rotated(pixels, quarterTurnsCounterclockwise: turns)
    }

    /// The part of `rect` inside the image; the whole image when they do not overlap.
    static func cropped(_ pixels: Pixels, to rect: FoldedRect) -> Pixels {
        let left = min(max(rect.x, 0), pixels.width)
        let top = min(max(rect.y, 0), pixels.height)
        let right = min(max(rect.x + rect.width, left), pixels.width)
        let bottom = min(max(rect.y + rect.height, top), pixels.height)
        guard right > left, bottom > top else { return pixels }
        if left == 0, top == 0, right == pixels.width, bottom == pixels.height { return pixels }
        let rowBytes = (right - left) * 4
        var output = Data(capacity: rowBytes * (bottom - top))
        for row in top..<bottom {
            let start = (row * pixels.width + left) * 4
            output.append(pixels.bytes[pixels.bytes.startIndex + start ..< pixels.bytes.startIndex + start + rowBytes])
        }
        return Pixels(width: right - left, height: bottom - top, bytes: output)
    }

    static func rgba(from frame: EmulatorFrame) throws -> Pixels {
        switch frame.format {
        case .rgba8888:
            return Pixels(width: frame.width, height: frame.height, bytes: Data(frame.bytes.prefix(frame.width * frame.height * 4)))
        case .png:
            return try rgba(from: try decodePNG(frame.bytes))
        }
    }

    static func decodePNG(_ data: Data) throws -> CGImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw ImageFailure(detail: "the PNG could not be decoded")
        }
        return image
    }

    static func rgba(from image: CGImage) throws -> Pixels {
        let width = image.width
        let height = image.height
        var bytes = Data(count: width * height * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { throw ImageFailure(detail: "could not draw a \(width) x \(height) image") }
        return Pixels(width: width, height: height, bytes: bytes)
    }

    /// Whole-pixel quarter turns, so no pixel is resampled.
    static func rotated(_ pixels: Pixels, quarterTurnsCounterclockwise turns: Int) -> Pixels {
        let turns = ((turns % 4) + 4) % 4
        guard turns != 0 else { return pixels }
        let width = pixels.width
        let height = pixels.height
        let newWidth = turns == 2 ? width : height
        let newHeight = turns == 2 ? height : width
        var output = Data(count: pixels.bytes.count)
        pixels.bytes.withUnsafeBytes { (source: UnsafeRawBufferPointer) in
            output.withUnsafeMutableBytes { (target: UnsafeMutableRawBufferPointer) in
                let from = source.bindMemory(to: UInt32.self)
                let to = target.bindMemory(to: UInt32.self)
                for y in 0..<height {
                    for x in 0..<width {
                        let destination: (Int, Int)
                        switch turns {
                        case 1: destination = (y, width - 1 - x)
                        case 2: destination = (width - 1 - x, height - 1 - y)
                        default: destination = (height - 1 - y, x)
                        }
                        to[destination.1 * newWidth + destination.0] = from[y * width + x]
                    }
                }
            }
        }
        return Pixels(width: newWidth, height: newHeight, bytes: output)
    }

    static func swapRedAndBlue(_ pixels: Pixels) -> Pixels {
        var bytes = pixels.bytes
        bytes.withUnsafeMutableBytes { buffer in
            var index = 0
            while index + 3 < buffer.count {
                let red = buffer[index]
                buffer[index] = buffer[index + 2]
                buffer[index + 2] = red
                index += 4
            }
        }
        return Pixels(width: pixels.width, height: pixels.height, bytes: bytes)
    }

    /// Alpha is ignored: the emulator's frames are opaque.
    static func cgImage(_ pixels: Pixels) throws -> CGImage {
        guard let provider = CGDataProvider(data: pixels.bytes as CFData),
              let image = CGImage(
                  width: pixels.width, height: pixels.height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: pixels.width * 4,
                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
              ) else {
            throw ImageFailure(detail: "could not build a \(pixels.width) x \(pixels.height) image")
        }
        return image
    }

    /// For the adb fallback, which cannot ask the device for a smaller frame.
    static func scaled(_ image: CGImage, by scale: Double) throws -> CGImage {
        guard scale < 1 else { return image }
        let width = max(1, Int((Double(image.width) * scale).rounded()))
        let height = max(1, Int((Double(image.height) * scale).rounded()))
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw ImageFailure(detail: "could not scale to \(width) x \(height)") }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let result = context.makeImage() else { throw ImageFailure(detail: "could not scale to \(width) x \(height)") }
        return result
    }

    /// How far into screencap's output a header may start: a multi-display phone prints a warning before it.
    static let maxLeadingBytes = 4096
    static let maxRawSide = 16384

    /// Raw `screencap`: little-endian u32 width, height, format (and a colour space from API 28), taken only where RGBA or RGBX rows fill the rest exactly.
    static func pixels(fromScreencapRaw output: Data) throws -> Pixels {
        guard let header = try rawHeader(output) else {
            throw ImageFailure(detail: "screencap's raw output has no header Offsider can read (\(output.count) bytes, starting \(failureDetail(output).prefix(80)))")
        }
        let start = output.startIndex + header.offset + header.length
        return Pixels(width: header.width, height: header.height, bytes: Data(output[start...]))
    }

    /// Where raw screencap output's header starts, its length and the image size, without copying the pixels; nil when none fits.
    static func rawHeader(_ output: Data) throws -> (offset: Int, length: Int, width: Int, height: Int)? {
        let bytes = [UInt8](output.prefix(maxLeadingBytes + 16))
        func word(_ at: Int) -> Int {
            Int(bytes[at]) | Int(bytes[at + 1]) << 8 | Int(bytes[at + 2]) << 16 | Int(bytes[at + 3]) << 24
        }
        for offset in 0...min(maxLeadingBytes, max(0, output.count - 12)) {
            for headerSize in [16, 12] where offset + headerSize <= bytes.count {
                let width = word(offset)
                let height = word(offset + 4)
                guard (1...maxRawSide).contains(width), (1...maxRawSide).contains(height),
                      output.count - offset == headerSize + width * height * 4 else { continue }
                let format = word(offset + 8)
                guard format == 1 || format == 2 else {
                    throw ImageFailure(detail: "screencap reported pixel format \(format), not RGBA_8888 or RGBX_8888")
                }
                return (offset, headerSize, width, height)
            }
        }
        return nil
    }

    /// The three lines `screencap` without `-d` prints first on a device with several displays.
    static let multiDisplayWarning = ["[Warning] Multiple displays were found", "A display ID can be specified with", "See \"dumpsys SurfaceFlinger --display-id\""]

    static func warnsOfSeveralDisplays(_ output: Data) -> Bool {
        String(decoding: output.prefix(maxLeadingBytes), as: UTF8.self).contains(multiDisplayWarning[0])
    }

    /// The first line of screencap's text that is not its multi-display warning, for an error message.
    static func failureDetail(_ output: Data) -> String {
        let lines = String(decoding: output.prefix(maxLeadingBytes), as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        let line = lines.first { line in !line.isEmpty && !multiDisplayWarning.contains { line.hasPrefix($0) } }
        return line.map { String($0.prefix(200)) } ?? "no output"
    }

    static let pngSignature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]

    /// The PNG within screencap's output, after any warning text it printed first; nil when there is none.
    static func png(fromScreencap output: Data) -> Data? {
        let window = output.prefix(maxLeadingBytes + pngSignature.count)
        guard let range = window.firstRange(of: pngSignature) else { return nil }
        return range.lowerBound == output.startIndex ? output : Data(output[range.lowerBound...])
    }

    /// The width and height in a PNG's IHDR chunk, read without decoding the image.
    static func pngSize(_ png: Data) -> (width: Int, height: Int)? {
        let bytes = [UInt8](png.prefix(24))
        guard bytes.count == 24, bytes.starts(with: pngSignature), bytes[12..<16].elementsEqual("IHDR".utf8) else { return nil }
        let word = { (at: Int) in bytes[at..<(at + 4)].reduce(0) { $0 << 8 | Int($1) } }
        return (word(16), word(20))
    }

    static func encodePNG(_ pixels: Pixels) throws -> Data {
        let image = try cgImage(pixels)
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output as CFMutableData, UTType.png.identifier as CFString, 1, nil) else {
            throw ImageFailure(detail: "could not start a PNG")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw ImageFailure(detail: "could not encode the PNG") }
        return output as Data
    }
}
