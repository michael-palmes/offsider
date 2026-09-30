import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Emulator frames made upright for the guest: a PNG passes through untouched when no turn is needed.
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
        if frame.format == .png, turns == 0 {
            return frame.bytes
        }
        return try encodePNG(rotated(try rgba(from: frame), quarterTurnsCounterclockwise: turns))
    }

    static func image(from frame: EmulatorFrame, guestRotation: Int) throws -> CGImage {
        let turns = PanelRotation.screenshotTurns(guestRotation: guestRotation, emulatorRotation: frame.emulatorRotation)
        return try cgImage(rotated(try rgba(from: frame), quarterTurnsCounterclockwise: turns))
    }

    /// For `stream-video --format bgra`: the frame upright, blue and red swapped.
    static func bgra(from frame: EmulatorFrame, guestRotation: Int) throws -> Pixels {
        let turns = PanelRotation.screenshotTurns(guestRotation: guestRotation, emulatorRotation: frame.emulatorRotation)
        return swapRedAndBlue(rotated(try rgba(from: frame), quarterTurnsCounterclockwise: turns))
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
