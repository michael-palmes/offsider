import Foundation

/// Where a resolved element sat on one read, for telling whether it is still animating.
public struct ElementPosition: Equatable, Sendable {
    public var point: UIPoint
    public var frame: UIFrame?

    public init(point: UIPoint, frame: UIFrame?) {
        self.point = point
        self.frame = frame
    }
}

public enum ElementMotion {
    /// True when two consecutive reads put the element within `tolerance` points of each other.
    public static func hasSettled(previous: ElementPosition, current: ElementPosition, tolerance: Double = 1) -> Bool {
        func close(_ a: Double, _ b: Double) -> Bool { abs(a - b) <= tolerance }
        guard close(previous.point.x, current.point.x), close(previous.point.y, current.point.y) else { return false }
        switch (previous.frame, current.frame) {
        case (nil, nil):
            return true
        case let (before?, after?):
            return close(before.x, after.x) && close(before.y, after.y)
                && close(before.width, after.width) && close(before.height, after.height)
        default:
            return false
        }
    }
}
