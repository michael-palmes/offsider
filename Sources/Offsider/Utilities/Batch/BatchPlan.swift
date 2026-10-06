import Foundation
import OffsiderCore

enum BatchPrimitive {
    case hidMergeable(InputEvent)
    case hidBarrier(InputEvent)
    case hostSleep(TimeInterval)
    case physicalTap(point: (x: Double, y: Double), preDelay: Double?, postDelay: Double?)
    /// A barrier through `TextInputSession` (the backend picks keys or a paste); `replace` sets the focused field instead.
    case text(String, replace: Bool)
    /// Work that reads the screen between inputs, such as focusing a field before its text.
    case run(@MainActor (any InputSession) async throws -> Void)
}

struct BatchPlan {
    let primitives: [BatchPrimitive]
}
