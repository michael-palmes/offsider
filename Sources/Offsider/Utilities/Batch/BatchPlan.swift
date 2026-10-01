import Foundation
import OffsiderCore

enum BatchPrimitive {
    case hidMergeable(InputEvent)
    case hidBarrier(InputEvent)
    case hostSleep(TimeInterval)
    case physicalTap(point: (x: Double, y: Double), preDelay: Double?, postDelay: Double?)
    /// A barrier typed through `TextInputSession`, for backends that choose key events or a paste themselves.
    case text(String)
}

struct BatchPlan {
    let primitives: [BatchPrimitive]
}
