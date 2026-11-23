import Accelerate
import CoreGraphics
import Foundation

/// A display surface another process draws into: 4 bytes a pixel in BGRA order, rows top to bottom.
public protocol FrameSurface: AnyObject {
    /// Changes whenever the pixels change.
    var seed: UInt32 { get }

    /// Calls `body` with the pixels locked for reading; nil when they cannot be locked or are not 4 bytes a pixel.
    func withLockedPixels<T>(_ body: (_ bytes: UnsafeRawBufferPointer, _ width: Int, _ height: Int, _ bytesPerRow: Int) throws -> T) throws -> T?
}

/// Video frames read straight from a display surface, turned upright and scaled with Accelerate in the same pass.
public final class SurfaceFrames {
    public enum Frame {
        case image(CGImage)
        /// The surface has not changed since the last frame returned.
        case unchanged
    }

    /// Quarter turns counterclockwise that make the display's native pixels upright.
    public let quarterTurns: Int
    public let scale: Double
    private let colourSpace: CGColorSpace
    private var lastSeed: UInt32?
    private var scaledScratch: (data: CFMutableData, width: Int, height: Int)?
    /// Locked reads, torn ones included.
    public private(set) var copies = 0

    public init(quarterTurns: Int, scale: Double, colourSpace: CGColorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()) {
        self.quarterTurns = ((quarterTurns % 4) + 4) % 4
        self.scale = scale
        self.colourSpace = colourSpace
    }

    /// The surface's pixels upright at `scale`; `.unchanged` only when `skipUnchanged` and its seed equals the last frame's.
    /// A seed that moves during the read is a torn frame, so it is read once more.
    public func next(from surface: any FrameSurface, skipUnchanged: Bool) throws -> Frame {
        var seed = surface.seed
        if skipUnchanged, seed == lastSeed { return .unchanged }
        var image = try read(surface)
        if surface.seed != seed {
            seed = surface.seed
            image = try read(surface)
        }
        lastSeed = surface.seed == seed ? seed : nil
        return .image(image)
    }

    /// Forgets the last frame, so the next one is read whatever its seed.
    public func reset() {
        lastSeed = nil
    }

    public static func scaledSide(_ side: Int, by scale: Double) -> Int {
        scale < 1 ? max(1, Int((Double(side) * scale).rounded())) : side
    }

    private func read(_ surface: any FrameSurface) throws -> CGImage {
        copies += 1
        let made = try unsafe surface.withLockedPixels { bytes, width, height, bytesPerRow in
            try unsafe draw(bytes, width: width, height: height, bytesPerRow: bytesPerRow)
        }
        guard let made else { throw ImageFailure(detail: "the simulator's display could not be read") }
        return made
    }

    private func draw(_ bytes: UnsafeRawBufferPointer, width: Int, height: Int, bytesPerRow: Int) throws -> CGImage {
        guard width > 0, height > 0, bytesPerRow >= width * 4, bytes.count >= (height - 1) * bytesPerRow + width * 4,
              let base = bytes.baseAddress else {
            throw ImageFailure(detail: "the simulator's display has no pixels")
        }
        var source = unsafe vImage_Buffer(data: UnsafeMutableRawPointer(mutating: base), height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: bytesPerRow)
        let scaledWidth = Self.scaledSide(width, by: scale), scaledHeight = Self.scaledSide(height, by: scale)
        let turned = quarterTurns % 2 == 1
        let outWidth = turned ? scaledHeight : scaledWidth, outHeight = turned ? scaledWidth : scaledHeight
        let outRowBytes = outWidth * 4
        guard let output = CFDataCreateMutable(nil, outRowBytes * outHeight) else {
            throw ImageFailure(detail: "could not allocate a \(outWidth) x \(outHeight) frame")
        }
        CFDataSetLength(output, outRowBytes * outHeight)
        var destination = unsafe vImage_Buffer(
            data: CFDataGetMutableBytePtr(output), height: vImagePixelCount(outHeight), width: vImagePixelCount(outWidth), rowBytes: outRowBytes
        )
        let error: vImage_Error
        switch (scaledWidth != width || scaledHeight != height, quarterTurns != 0) {
        case (false, false):
            error = unsafe vImageCopyBuffer(&source, &destination, 4, vImage_Flags(kvImageNoFlags))
        case (true, false):
            error = unsafe vImageScale_ARGB8888(&source, &destination, nil, vImage_Flags(kvImageNoFlags))
        case (false, true):
            error = unsafe rotate(&source, into: &destination)
        case (true, true):
            var scaled = try unsafe scratch(width: scaledWidth, height: scaledHeight)
            let scaling = unsafe vImageScale_ARGB8888(&source, &scaled, nil, vImage_Flags(kvImageNoFlags))
            error = scaling == kvImageNoError ? unsafe rotate(&scaled, into: &destination) : scaling
        }
        guard error == kvImageNoError else {
            throw ImageFailure(detail: "could not turn or scale the frame (vImage \(error))")
        }
        guard let provider = CGDataProvider(data: output),
              let image = unsafe CGImage(
                  width: outWidth, height: outHeight, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: outRowBytes, space: colourSpace,
                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
              ) else {
            throw ImageFailure(detail: "could not build a \(outWidth) x \(outHeight) frame")
        }
        return image
    }

    private func rotate(_ source: inout vImage_Buffer, into destination: inout vImage_Buffer) -> vImage_Error {
        var black: [UInt8] = [0, 0, 0, 255]
        return unsafe vImageRotate90_ARGB8888(&source, &destination, UInt8(quarterTurns), &black, vImage_Flags(kvImageNoFlags))
    }

    /// Reused between frames, since only the turned copy outlives a frame.
    private func scratch(width: Int, height: Int) throws -> vImage_Buffer {
        let data: CFMutableData
        if let kept = scaledScratch, kept.width == width, kept.height == height {
            data = kept.data
        } else {
            guard let made = CFDataCreateMutable(nil, width * height * 4) else {
                throw ImageFailure(detail: "could not allocate a \(width) x \(height) frame")
            }
            CFDataSetLength(made, width * height * 4)
            scaledScratch = (made, width, height)
            data = made
        }
        return unsafe vImage_Buffer(data: CFDataGetMutableBytePtr(data), height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: width * 4)
    }
}
