import Foundation

/// Named phase durations for `OFFSIDER_TIMINGS=1`, measured against an injected nanosecond clock.
public struct PhaseTimings: Sendable {
    public static let environmentKey = "OFFSIDER_TIMINGS"
    public static let linePrefix = "offsider timing:"

    public struct Phase: Equatable, Sendable {
        public let name: String
        public let nanoseconds: UInt64

        public init(name: String, nanoseconds: UInt64) {
            self.name = name
            self.nanoseconds = nanoseconds
        }

        public var milliseconds: UInt64 {
            (nanoseconds + 500_000) / 1_000_000
        }

        public var line: String {
            "\(PhaseTimings.linePrefix) \(name) \(milliseconds) ms"
        }
    }

    public typealias Clock = @Sendable () -> UInt64

    public private(set) var phases: [Phase] = []
    private let now: Clock

    public init(now: @escaping Clock = PhaseTimings.monotonicNanoseconds) {
        self.now = now
    }

    public static func isEnabled(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        environment[environmentKey] == "1"
    }

    public static let monotonicNanoseconds: Clock = {
        clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
    }

    public func start() -> UInt64 {
        now()
    }

    @discardableResult
    public mutating func record(_ name: String, since start: UInt64) -> Phase {
        let end = now()
        let phase = Phase(name: name, nanoseconds: end >= start ? end - start : 0)
        phases.append(phase)
        return phase
    }

    public var lines: [String] {
        phases.map(\.line)
    }
}
