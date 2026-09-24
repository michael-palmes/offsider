import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
import OffsiderCore

@Suite("Image Fingerprint Tests")
struct ImageFingerprintTests {
    private let width = 64
    private let height = 128

    private func pixels(_ edit: (inout [UInt8]) -> Void = { _ in }) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for index in stride(from: 0, to: bytes.count, by: 4) {
            bytes[index] = UInt8(index % 251)
            bytes[index + 1] = 90
            bytes[index + 2] = 180
            bytes[index + 3] = 255
        }
        edit(&bytes)
        return bytes
    }

    private func setPixel(_ bytes: inout [UInt8], x: Int, y: Int) {
        bytes[(y * width + x) * 4] &+= 17
    }

    private func fingerprint(_ bytes: [UInt8], excludingTopPixels: Int = 0) -> ImageFingerprint {
        bytes.withUnsafeBytes {
            ImageFingerprint(rgba: $0, width: width, height: height, bytesPerRow: width * 4, excludingTopPixels: excludingTopPixels)
        }
    }

    private func png(_ bytes: [UInt8], description: String) throws -> Data {
        let provider = try #require(CGDataProvider(data: Data(bytes) as CFData))
        let image = try #require(CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        ))
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        let properties = [kCGImagePropertyPNGDictionary: [kCGImagePropertyPNGDescription: description]] as CFDictionary
        CGImageDestinationAddImage(destination, image, properties)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }

    @Test("Identical pixels have no changed tiles")
    func identicalPixels() {
        #expect(fingerprint(pixels()).changedTiles(comparedTo: fingerprint(pixels())) == [])
    }

    @Test("A one-pixel change changes exactly one tile")
    func onePixelChangesOneTile() {
        let changed = fingerprint(pixels { setPixel(&$0, x: 40, y: 90) })
        #expect(fingerprint(pixels()).changedTiles(comparedTo: changed)?.count == 1)
    }

    @Test("The same pixels in PNGs with different metadata fingerprint equally")
    func decodedPixelsNotBytes() throws {
        let first = try png(pixels(), description: "first")
        let second = try png(pixels(), description: "second capture")
        #expect(first != second)
        let a = try #require(ImageFingerprint(pngData: first))
        let b = try #require(ImageFingerprint(pngData: second))
        #expect(a == b)
    }

    @Test("Different image sizes cannot be compared and count as changed")
    func sizeMismatch() {
        let small = [UInt8](repeating: 0, count: 32 * 32 * 4).withUnsafeBytes {
            ImageFingerprint(rgba: $0, width: 32, height: 32, bytesPerRow: 32 * 4)
        }
        let full = fingerprint(pixels())
        #expect(full.changedTiles(comparedTo: small) == nil)
        #expect(ScreenChange.detect(before: full, after: [small]))
    }

    @Test("A change inside the excluded top band is ignored")
    func excludedTopBand() {
        let before = fingerprint(pixels(), excludingTopPixels: 10)
        let clockTick = fingerprint(pixels { setPixel(&$0, x: 5, y: 3) }, excludingTopPixels: 10)
        #expect(before.changedTiles(comparedTo: clockTick) == [])
    }

    @Test("Screen change ignores a tile that alternates across the after-shots")
    func alternatingTileIsVolatile() {
        let before = fingerprint(pixels())
        let caretOn = fingerprint(pixels { setPixel(&$0, x: 10, y: 60) })
        #expect(!ScreenChange.detect(before: before, after: [caretOn, before, caretOn]))

        let realChange = fingerprint(pixels {
            setPixel(&$0, x: 10, y: 60)
            setPixel(&$0, x: 50, y: 120)
        })
        let caretAndChange = fingerprint(pixels { setPixel(&$0, x: 50, y: 120) })
        #expect(ScreenChange.detect(before: before, after: [realChange, caretAndChange, realChange]))
        #expect(!ScreenChange.detect(before: before, after: [before, before, before]))
    }
}
