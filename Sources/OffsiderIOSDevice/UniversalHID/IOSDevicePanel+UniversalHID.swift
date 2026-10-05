import Foundation

extension IOSDevicePanel {
    /// A UI point as the main touchscreen's 0...65535 coordinates. The touchscreen runs along the panel's portrait axes:
    /// on a landscape-native iPad its x climbs from the UI's bottom edge to its top and its y from left to right.
    public func touchscreenPoint(x: Double, y: Double) -> (x: UInt16, y: UInt16) {
        let native = panelPoint(x: x, y: y)
        let fraction = fraction(x: native.x, y: native.y)
        guard width > height else {
            return (UniversalHIDReport.axis(fraction.x), UniversalHIDReport.axis(fraction.y))
        }
        return (UniversalHIDReport.axis(1 - fraction.y), UniversalHIDReport.axis(fraction.x))
    }
}
