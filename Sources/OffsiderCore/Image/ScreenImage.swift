import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum ImageFormat: Equatable, Sendable {
    case png
    case jpeg(quality: Int)

    public static let defaultJPEGQuality = 85

    public var fileExtension: String {
        switch self {
        case .png: "png"
        case .jpeg: "jpg"
        }
    }

    public var name: String {
        switch self {
        case .png: "png"
        case .jpeg: "jpeg"
        }
    }
}

public struct ImageFailure: LocalizedError, CustomStringConvertible, Equatable, Sendable {
    public let detail: String

    public init(detail: String) {
        self.detail = detail
    }

    public var errorDescription: String? { description }
    public var description: String { "Could not process the screenshot: \(detail)." }
}

/// Decoding, quarter turns, crops, resizes and encoding for screenshots, through CoreGraphics and ImageIO only.
public enum ScreenImage {
    public static func decode(_ data: Data) throws -> CGImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw ImageFailure(detail: "the image could not be decoded")
        }
        return image
    }

    /// True when the data is a JPEG, whose compression can make equal screens differ.
    public static func isJPEG(_ data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let type = CGImageSourceGetType(source) else {
            return false
        }
        return UTType(type as String)?.conforms(to: .jpeg) == true
    }

    /// Whole-pixel quarter turns, so no pixel is resampled.
    public static func rotated(_ image: CGImage, quarterTurnsCounterclockwise turns: Int) throws -> CGImage {
        let turns = ((turns % 4) + 4) % 4
        guard turns != 0 else { return image }
        let width = image.width
        let height = image.height
        let source = try pixels(of: image)
        let newWidth = turns == 2 ? width : height
        let newHeight = turns == 2 ? height : width
        var output = [UInt32](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                let destination: (x: Int, y: Int)
                switch turns {
                case 1: destination = (y, width - 1 - x)
                case 2: destination = (width - 1 - x, height - 1 - y)
                default: destination = (height - 1 - y, x)
                }
                output[destination.y * newWidth + destination.x] = source[y * width + x]
            }
        }
        return try makeImage(output, width: newWidth, height: newHeight, colourSpace: colourSpace(of: image))
    }

    /// `rect` is in pixels from the top-left corner and must lie within the image.
    public static func cropped(_ image: CGImage, to rect: PixelRect) throws -> CGImage {
        guard rect.width > 0, rect.height > 0, rect.x >= 0, rect.y >= 0,
              rect.x + rect.width <= image.width, rect.y + rect.height <= image.height else {
            throw ImageFailure(detail: "the crop \(rect.x),\(rect.y),\(rect.width),\(rect.height) lies outside the \(image.width) x \(image.height) image")
        }
        if rect == PixelRect(x: 0, y: 0, width: image.width, height: image.height) { return image }
        guard let cropped = image.cropping(to: CGRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height)) else {
            throw ImageFailure(detail: "could not crop to \(rect.width) x \(rect.height)")
        }
        return cropped
    }

    public static func scaled(_ image: CGImage, width: Int, height: Int) throws -> CGImage {
        guard width > 0, height > 0 else {
            throw ImageFailure(detail: "could not scale to \(width) x \(height)")
        }
        if width == image.width, height == image.height { return image }
        guard let context = context(width: width, height: height, colourSpace: colourSpace(of: image)) else {
            throw ImageFailure(detail: "could not scale to \(width) x \(height)")
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let result = context.makeImage() else {
            throw ImageFailure(detail: "could not scale to \(width) x \(height)")
        }
        return result
    }

    /// Fills each top-left-origin pixel rectangle with opaque black; no blur, so nothing underneath survives.
    public static func masked(_ image: CGImage, pixelRects: [CGRect]) throws -> CGImage {
        guard !pixelRects.isEmpty else { return image }
        let width = image.width
        let height = image.height
        guard let context = context(width: width, height: height, colourSpace: colourSpace(of: image)) else {
            throw ImageFailure(detail: "could not draw a \(width) x \(height) image")
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
        for rect in pixelRects {
            let rounded = CGRect(
                x: rect.minX.rounded(.down), y: rect.minY.rounded(.down),
                width: rect.maxX.rounded(.up) - rect.minX.rounded(.down), height: rect.maxY.rounded(.up) - rect.minY.rounded(.down)
            ).intersection(CGRect(x: 0, y: 0, width: width, height: height))
            guard !rounded.isNull, !rounded.isEmpty else { continue }
            context.fill(CGRect(x: rounded.minX, y: CGFloat(height) - rounded.maxY, width: rounded.width, height: rounded.height))
        }
        guard let result = context.makeImage() else {
            throw ImageFailure(detail: "could not mask the \(width) x \(height) image")
        }
        return result
    }

    public static func encode(_ image: CGImage, as format: ImageFormat) throws -> Data {
        let output = NSMutableData()
        let type: UTType
        var properties: [CFString: Any] = [:]
        switch format {
        case .png:
            type = .png
        case .jpeg(let quality):
            type = .jpeg
            properties[kCGImageDestinationLossyCompressionQuality] = Double(min(max(quality, 1), 100)) / 100
        }
        guard let destination = CGImageDestinationCreateWithData(output as CFMutableData, type.identifier as CFString, 1, nil) else {
            throw ImageFailure(detail: "could not start a \(format.name.uppercased())")
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw ImageFailure(detail: "could not encode the \(format.name.uppercased())")
        }
        return output as Data
    }

    /// The image's own RGB space, so an encode and decode round trip fingerprints the same as the image in memory.
    static func colourSpace(of image: CGImage) -> CGColorSpace {
        if let space = image.colorSpace, space.model == .rgb, space.supportsOutput {
            return space
        }
        return CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    }

    static func context(width: Int, height: Int, colourSpace: CGColorSpace, data: UnsafeMutableRawPointer? = nil) -> CGContext? {
        CGContext(
            data: data, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: colourSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
    }

    /// One `UInt32` a pixel (RGBA bytes in memory order), rows top to bottom, drawn into `colourSpace` or the image's own.
    static func pixels(of image: CGImage, colourSpace: CGColorSpace? = nil) throws -> [UInt32] {
        let width = image.width
        let height = image.height
        var pixels = [UInt32](repeating: 0, count: width * height)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = context(width: width, height: height, colourSpace: colourSpace ?? self.colourSpace(of: image), data: buffer.baseAddress) else {
                return false
            }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { throw ImageFailure(detail: "could not draw a \(width) x \(height) image") }
        return pixels
    }

    static func makeImage(_ pixels: [UInt32], width: Int, height: Int, colourSpace: CGColorSpace) throws -> CGImage {
        let data = pixels.withUnsafeBytes { Data($0) }
        guard let provider = CGDataProvider(data: data as CFData),
              let image = CGImage(
                  width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                  space: colourSpace, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
              ) else {
            throw ImageFailure(detail: "could not build a \(width) x \(height) image")
        }
        return image
    }
}
