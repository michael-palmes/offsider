import Foundation

public enum ElementMotion {
    /// True when two consecutive reads put the activation point within `tolerance` points; a frame that only changes size has settled.
    public static func hasSettled(previous: UIPoint, current: UIPoint, tolerance: Double = 1) -> Bool {
        abs(previous.x - current.x) <= tolerance && abs(previous.y - current.y) <= tolerance
    }
}
