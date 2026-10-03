import Foundation

/// Polls a device setting, such as the orientation or the posture, until it reads as the target.
public enum StateWait {
    public enum Outcome<Value: Equatable & Sendable>: Equatable, Sendable {
        case reached
        case timedOut(last: Value?)
    }

    /// Reads at least once; sends `request` again once, halfway to the deadline, in case the first was dropped.
    @MainActor
    public static func run<Value: Equatable & Sendable>(
        target: Value,
        timeout: TimeInterval,
        interval: Duration = .milliseconds(100),
        read: @MainActor () async throws -> Value?,
        request: @MainActor () async throws -> Void,
        sleep: @MainActor (Duration) async throws -> Void,
        now: @MainActor () -> TimeInterval
    ) async throws -> Outcome<Value> {
        let start = now()
        var resent = false
        while true {
            let current = try await read()
            if current == target { return .reached }
            let elapsed = now() - start
            if elapsed >= timeout { return .timedOut(last: current) }
            if !resent, elapsed >= timeout / 2 {
                resent = true
                try await request()
            }
            try await sleep(interval)
        }
    }
}
