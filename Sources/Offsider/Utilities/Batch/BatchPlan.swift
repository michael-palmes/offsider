import Foundation
import OffsiderCore

enum BatchPrimitive {
    case hidMergeable(InputEvent)
    case hidBarrier(InputEvent)
    case hostSleep(TimeInterval)
    case physicalTap(point: (x: Double, y: Double), preDelay: Double?, postDelay: Double?)
    /// A barrier through `TextInputSession` (the backend picks keys or a paste); `replace` sets the focused field instead.
    case text(String, replace: Bool)
}

struct BatchPlan {
    let primitives: [BatchPrimitive]
}
