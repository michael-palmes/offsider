/// Sizes worked out from device-reported dimensions without trapping on overflow.
public enum PixelMath {
    /// The largest side, in pixels, Offsider accepts from any device or stream.
    public static let maxSide = 16_384
    /// The most points a lowered swipe or drag moves through.
    public static let maxSwipeSteps = 1000

    /// `width * height * bytesPerPixel`, or nil when a side is outside 1 to `maxSide` or the product overflows.
    public static func byteCount(width: Int, height: Int, bytesPerPixel: Int = 4) -> Int? {
        guard (1...maxSide).contains(width), (1...maxSide).contains(height), bytesPerPixel > 0 else { return nil }
        let (pixels, overflow) = width.multipliedReportingOverflow(by: height)
        let (bytes, overflowBytes) = pixels.multipliedReportingOverflow(by: bytesPerPixel)
        return overflow || overflowBytes ? nil : bytes
    }

    /// A step count from a `Double` ratio, clamped to 1 to `maxSwipeSteps` before it becomes an `Int`; NaN is 1.
    public static func swipeSteps(_ ratio: Double) -> Int {
        guard !ratio.isNaN else { return 1 }
        return Int(min(max(ratio, 1), Double(maxSwipeSteps)))
    }
}
