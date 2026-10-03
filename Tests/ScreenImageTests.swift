import CoreGraphics
import Foundation
import Testing
import OffsiderCore

/// In-memory sRGB images: a grey background with chosen pixels painted red.
enum TestImages {
    static func make(width: Int, height: Int, marked: [(x: Int, y: Int)] = [], background: UInt8 = 120) -> CGImage {
        var bytes = [UInt8](repeating: background, count: width * height * 4)
        for index in stride(from: 3, to: bytes.count, by: 4) { bytes[index] = 255 }
        for point in marked {
            let offset = (point.y * width + point.x) * 4
            bytes[offset] = 255
            bytes[offset + 1] = 0
            bytes[offset + 2] = 0
        }
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )!
    }

    /// The red pixels, top-left origin.
    static func markedPixels(_ image: CGImage) -> [(x: Int, y: Int)] {
        let width = image.width
        let height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        bytes.withUnsafeMutableBytes { buffer in
            let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )!
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        var marked: [(x: Int, y: Int)] = []
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                if bytes[offset] > 200, bytes[offset + 1] < 60 { marked.append((x, y)) }
            }
        }
        return marked
    }
}

@Suite("Screen Image")
struct ScreenImageTests {
    @Test("Quarter turns counterclockwise move the top-right pixel round the corners", arguments: [
        (1, 0, 0),
        (2, 0, 5),
        (3, 5, 3),
    ])
    func rotation(turns: Int, expectedX: Int, expectedY: Int) throws {
        let image = TestImages.make(width: 4, height: 6, marked: [(3, 0)])
        let rotated = try ScreenImage.rotated(image, quarterTurnsCounterclockwise: turns)
        let swapsSides = turns % 2 == 1
        #expect(rotated.width == (swapsSides ? 6 : 4))
        #expect(rotated.height == (swapsSides ? 4 : 6))
        let marked = TestImages.markedPixels(rotated)
        #expect(marked.count == 1)
        #expect(marked.first?.x == expectedX && marked.first?.y == expectedY)
    }

    @Test("A full turn returns the image unchanged")
    func fullTurn() throws {
        let image = TestImages.make(width: 4, height: 6, marked: [(3, 0)])
        let rotated = try ScreenImage.rotated(image, quarterTurnsCounterclockwise: 4)
        #expect(rotated.width == 4 && rotated.height == 6)
        #expect(TestImages.markedPixels(rotated).first.map { $0.x == 3 && $0.y == 0 } == true)
    }

    @Test("Cropping takes pixels from the top-left origin")
    func cropFromTopLeft() throws {
        let image = TestImages.make(width: 30, height: 60, marked: [(12, 25)])
        let cropped = try ScreenImage.cropped(image, to: PixelRect(x: 10, y: 20, width: 5, height: 10))
        #expect(cropped.width == 5 && cropped.height == 10)
        #expect(TestImages.markedPixels(cropped).first.map { $0.x == 2 && $0.y == 5 } == true)
    }

    @Test("A crop beyond the image is refused")
    func cropOutside() {
        let image = TestImages.make(width: 30, height: 60)
        #expect(throws: ImageFailure.self) {
            try ScreenImage.cropped(image, to: PixelRect(x: 20, y: 0, width: 20, height: 10))
        }
    }

    @Test("Crop then scale gives the requested size")
    func cropThenScale() throws {
        let image = TestImages.make(width: 1206, height: 2622)
        let cropped = try ScreenImage.cropped(image, to: PixelRect(x: 30, y: 300, width: 600, height: 150))
        let scaled = try ScreenImage.scaled(cropped, width: 200, height: 50)
        #expect(scaled.width == 200 && scaled.height == 50)
    }

    @Test("PNG and JPEG encode and decode back at the same size", arguments: [ImageFormat.png, .jpeg(quality: 85), .jpeg(quality: 1)])
    func roundTrip(format: ImageFormat) throws {
        let image = TestImages.make(width: 40, height: 70, marked: [(5, 5)])
        let data = try ScreenImage.encode(image, as: format)
        let decoded = try ScreenImage.decode(data)
        #expect(decoded.width == 40 && decoded.height == 70)
        #expect(ScreenImage.isJPEG(data) == (format != .png))
    }

    @Test("Data that is not an image fails to decode")
    func decodeGarbage() {
        #expect(throws: ImageFailure.self) {
            try ScreenImage.decode(Data("not an image".utf8))
        }
    }
}
