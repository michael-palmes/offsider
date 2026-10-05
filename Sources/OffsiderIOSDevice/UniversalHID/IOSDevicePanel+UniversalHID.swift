import Foundation

extension IOSDevicePanel {
    /// A UI point as 0...65535 touchscreen coordinates on the panel's portrait axes (a landscape-native iPad's x runs bottom to top, y left to right).
    public func touchscreenPoint(x: Double, y: Double) -> (x: UInt16, y: UInt16) {
        let native = panelPoint(x: x, y: y)
        let fraction = fraction(x: native.x, y: native.y)
        guard width > height else {
            return (UniversalHIDReport.axis(fraction.x), UniversalHIDReport.axis(fraction.y))
        }
        return (UniversalHIDReport.axis(1 - fraction.y), UniversalHIDReport.axis(fraction.x))
    }
}
