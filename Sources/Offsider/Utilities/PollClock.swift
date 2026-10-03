import Foundation

/// How a poll reads the time and waits, injected so tests run on a scripted clock that a busy scheduler cannot move.
struct PollClock {
    var now: @MainActor () -> TimeInterval
    var sleep: @MainActor (Duration) async throws -> Void

    static var live: PollClock {
        PollClock(now: { ProcessInfo.processInfo.systemUptime }, sleep: { try await Task.sleep(for: $0) })
    }
}
