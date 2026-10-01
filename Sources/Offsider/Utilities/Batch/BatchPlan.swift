import Foundation
import OffsiderCore

enum BatchPrimitive {
    case hidMergeable(InputEvent)
    case hidBarrier(InputEvent)
    case hostSleep(TimeInterval)
    case physicalTap(point: (x: Double, y: Double), preDelay: Double?, postDelay: Double?)
}

struct BatchPlan {
    let primitives: [BatchPrimitive]
}
