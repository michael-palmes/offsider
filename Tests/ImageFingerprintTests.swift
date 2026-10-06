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

    private func fingerprint(
        _ bytes: [UInt8], columns: Int = 16, rows: Int = 32, excludingTopPixels: Int = 0, excludingBottomPixels: Int = 0, tolerance: Int = 0
    ) -> ImageFingerprint {
        bytes.withUnsafeBytes {
            ImageFingerprint(
                rgba: $0, width: width, height: height, bytesPerRow: width * 4, columns: columns, rows: rows,
                excludingTopPixels: excludingTopPixels, excludingBottomPixels: excludingBottomPixels, tolerance: tolerance
            )
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

    @Test("With a tolerance, video-like noise of a few units in scattered pixels changes no tile, while exact hashing sees it")
    func toleranceIgnoresNoise() {
        let noisy = pixels { bytes in
            for (x, y) in [(3, 3), (20, 9), (41, 70), (60, 127), (7, 100)] {
                bytes[(y * width + x) * 4 + 1] &+= 8
                bytes[(y * width + x) * 4 + 2] &-= 5
            }
        }
        #expect(fingerprint(pixels(), tolerance: 6).changedTiles(comparedTo: fingerprint(noisy, tolerance: 6)) == [])
        #expect(fingerprint(pixels()).changedTiles(comparedTo: fingerprint(noisy))?.count == 5)
    }

    @Test("With a tolerance, a two-pixel-wide caret still changes the 32-pixel tile it is drawn in")
    func toleranceKeepsThinLines() {
        let caret = pixels { bytes in
            for y in 20..<28 {
                for x in 9..<11 {
                    bytes[(y * width + x) * 4 + 1] = 0
                    bytes[(y * width + x) * 4 + 2] = 0
                }
            }
        }
        let before = fingerprint(pixels(), columns: 2, rows: 4, tolerance: 6)
        #expect(before.changedTiles(comparedTo: fingerprint(caret, columns: 2, rows: 4, tolerance: 6)) == [0])
    }

    @Test("Exact and tolerant fingerprints put a pixel row in the same tile when the height does not divide evenly")
    func rowsMapAlikeInBothModes() {
        let width = 4, height = 10
        func print(_ shade: UInt8, tolerance: Int) -> ImageFingerprint {
            var bytes = [UInt8](repeating: 200, count: width * height * 4)
            for x in 0..<width { bytes[(3 * width + x) * 4] = shade }
            return bytes.withUnsafeBytes {
                ImageFingerprint(rgba: $0, width: width, height: height, bytesPerRow: width * 4, columns: 1, rows: 3, tolerance: tolerance)
            }
        }
        for tolerance in [0, 6] {
            #expect(print(200, tolerance: tolerance).changedTiles(comparedTo: print(0, tolerance: tolerance)) == [0], "tolerance \(tolerance)")
        }
    }

    @Test("Fingerprints taken with different tolerances cannot be compared and count as changed")
    func differentTolerances() {
        #expect(fingerprint(pixels(), tolerance: 6).changedTiles(comparedTo: fingerprint(pixels())) == nil)
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

    @Test("A change inside the excluded bottom band is ignored, and one just above it is not")
    func excludedBottomBand() {
        let before = fingerprint(pixels(), excludingTopPixels: 10, excludingBottomPixels: 12)
        let navigationBar = fingerprint(pixels { setPixel(&$0, x: 5, y: height - 12) }, excludingTopPixels: 10, excludingBottomPixels: 12)
        let content = fingerprint(pixels { setPixel(&$0, x: 5, y: height - 13) }, excludingTopPixels: 10, excludingBottomPixels: 12)
        #expect(before.changedTiles(comparedTo: navigationBar) == [])
        #expect(before.changedTiles(comparedTo: content)?.count == 1)
    }

    @Test("Bands that overlap exclude the whole image without trapping")
    func overlappingBands() {
        let before = fingerprint(pixels(), excludingTopPixels: 100, excludingBottomPixels: 100)
        let changed = fingerprint(pixels { setPixel(&$0, x: 5, y: 60) }, excludingTopPixels: 100, excludingBottomPixels: 100)
        #expect(before.changedTiles(comparedTo: changed) == [])
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

    @Test("A change inside a region is detected and one outside it is not")
    func regionScopesChanges() throws {
        let region = PixelRect(x: 10, y: 20, width: 30, height: 40)
        let before = try #require(ImageFingerprint(image: TestImages.make(width: 64, height: 128), region: region))
        let inside = try #require(ImageFingerprint(image: TestImages.make(width: 64, height: 128, marked: [(20, 30)]), region: region))
        let outside = try #require(ImageFingerprint(image: TestImages.make(width: 64, height: 128, marked: [(50, 100)]), region: region))
        #expect(before.width == 30 && before.height == 40)
        #expect(before.changedTiles(comparedTo: inside)?.count == 1)
        #expect(before.changedTiles(comparedTo: outside) == [])
    }

    @Test("The changed fraction counts only tiles outside the excluded bands")
    func changedFractionOverComparedTiles() {
        let before = fingerprint(pixels(), excludingTopPixels: 64)
        let changed = fingerprint(pixels { setPixel(&$0, x: 5, y: 100) }, excludingTopPixels: 64)
        #expect(before.comparedTileCount == 16 * 16)
        #expect(before.changedFraction(comparedTo: changed) == 1.0 / 256)
        #expect(fingerprint(pixels()).changedFraction(comparedTo: fingerprint(pixels { setPixel(&$0, x: 5, y: 100) })) == 1.0 / 512)
    }

    @Test("Grids of different sizes have no changed fraction")
    func changedFractionNeedsMatchingGrids() {
        let small = [UInt8](repeating: 0, count: 32 * 32 * 4).withUnsafeBytes {
            ImageFingerprint(rgba: $0, width: 32, height: 32, bytesPerRow: 32 * 4)
        }
        #expect(fingerprint(pixels()).changedFraction(comparedTo: small) == nil)
    }

    @Test("An image and its PNG encoding fingerprint equally")
    func imageMatchesItsPNG() throws {
        let image = TestImages.make(width: 64, height: 128, marked: [(3, 4)])
        let fromImage = try #require(ImageFingerprint(image: image))
        let fromPNG = try #require(ImageFingerprint(pngData: try ScreenImage.encode(image, as: .png)))
        #expect(fromImage == fromPNG)
    }
}
