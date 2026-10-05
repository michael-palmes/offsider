import Foundation

public struct ScreenRegionError: LocalizedError, CustomStringConvertible, Equatable, Sendable {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var errorDescription: String? { message }
    public var description: String { message }
}

/// A rectangle in points (dp on Android), as describe-ui prints frames.
public struct PointRegion: Equatable, Sendable, CustomStringConvertible {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    /// Parses "x,y,width,height": a non-negative origin and a positive size; `option` names the flag in errors.
    public static func parse(_ text: String, option: String = "--region") throws -> PointRegion {
        let parts = text.split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        let values = parts.compactMap(Double.init)
        guard parts.count == 4, values.count == 4, values.allSatisfy(\.isFinite) else {
            throw ScreenRegionError("\(option) takes x,y,width,height in points, for example 0,100,402,300; got \"\(text)\".")
        }
        guard values[0] >= 0, values[1] >= 0 else {
            throw ScreenRegionError("\(option) \(text) starts at a negative coordinate; x and y must be 0 or more.")
        }
        guard values[2] > 0, values[3] > 0 else {
            throw ScreenRegionError("\(option) \(text) has no area; width and height must be greater than 0.")
        }
        return PointRegion(x: values[0], y: values[1], width: values[2], height: values[3])
    }

    public var description: String {
        [x, y, width, height].map(ScreenGeometry.format).joined(separator: ",")
    }
}

/// A rectangle in image pixels from the top-left corner.
public struct PixelRect: Equatable, Sendable {
    public var x: Int
    public var y: Int
    public var width: Int
    public var height: Int

    public init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

public enum ScreenGeometry {
    /// Longer side over longer side, so it holds when the image is portrait-native and the screen reports landscape.
    public static func pixelsPerPoint(imageWidth: Int, imageHeight: Int, screenWidth: Double, screenHeight: Double) -> Double? {
        let screenSide = max(screenWidth, screenHeight)
        let imageSide = max(imageWidth, imageHeight)
        guard screenSide > 0, imageSide > 0 else { return nil }
        return Double(imageSide) / screenSide
    }

    /// Rounds outward (floor the origin, ceil the far edge) and clamps to the image; throws when nothing is left.
    public static func pixelRect(for region: PointRegion, pixelsPerPoint: Double, imageWidth: Int, imageHeight: Int) throws -> PixelRect {
        func pixel(_ points: Double, _ rule: FloatingPointRoundingRule, limit: Int) -> Int {
            let value = (points * pixelsPerPoint).rounded(rule)
            return value.isNaN ? 0 : Int(min(Double(limit), max(0, value)))
        }
        let left = pixel(region.x, .down, limit: imageWidth)
        let top = pixel(region.y, .down, limit: imageHeight)
        let right = pixel(region.x + region.width, .up, limit: imageWidth)
        let bottom = pixel(region.y + region.height, .up, limit: imageHeight)
        guard pixelsPerPoint > 0, right > left, bottom > top else {
            let width = format(Double(imageWidth) / pixelsPerPoint)
            let height = format(Double(imageHeight) / pixelsPerPoint)
            throw ScreenRegionError("--region \(region) lies outside the \(width) x \(height) pt screen. Take coordinates from describe-ui.")
        }
        return PixelRect(x: left, y: top, width: right - left, height: bottom - top)
    }

    /// The points a pixel rectangle covers, for reporting the region actually captured.
    public static func pointRegion(for rect: PixelRect, pixelsPerPoint: Double) -> PointRegion {
        PointRegion(
            x: Double(rect.x) / pixelsPerPoint,
            y: Double(rect.y) / pixelsPerPoint,
            width: Double(rect.width) / pixelsPerPoint,
            height: Double(rect.height) / pixelsPerPoint
        )
    }

    /// Rounded to 0.01, the precision of describe-ui frames.
    public static func format(_ value: Double) -> String {
        let rounded = (value * 100).rounded() / 100
        return rounded.rounded() == rounded && abs(rounded) < 1e15 ? String(Int(rounded)) : String(rounded)
    }
}
