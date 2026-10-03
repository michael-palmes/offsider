import Foundation
@testable import Offsider

/// Time that passes only when the code under test sleeps, so a busy machine cannot move a deadline.
@MainActor
final class ScriptedClock {
    private(set) var now: TimeInterval = 0

    var poll: PollClock {
        PollClock(
            now: { self.now },
            sleep: { self.now += Double($0.components.seconds) + Double($0.components.attoseconds) / 1e18 }
        )
    }
}
