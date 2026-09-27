import Foundation
import OffsiderCore

extension InputEvent {
    /// `[delay(pre)?, main, delay(post)?]` as a composite, or `main` alone when neither delay is positive.
    static func delayed(_ main: InputEvent, pre: Double?, post: Double?) -> InputEvent {
        var events: [InputEvent] = []
        if let pre, pre > 0 {
            events.append(.delay(pre))
        }
        events.append(main)
        if let post, post > 0 {
            events.append(.delay(post))
        }
        return events.count == 1 ? events[0] : .composite(events)
    }
}
