import Foundation
import OffsiderCore

/// `OFFSIDER_TIMINGS=1` lines from the iOS device backend; off by default, then `measure` is a plain call.
public struct IOSDeviceTiming: Sendable {
    let sink: (@Sendable (String) -> Void)?

    public static let disabled = IOSDeviceTiming(sink: nil)

    public static func printing(to sink: @escaping @Sendable (String) -> Void) -> IOSDeviceTiming {
        IOSDeviceTiming(sink: sink)
    }

    func measure<T>(_ phase: String, isolation: isolated (any Actor)? = #isolation, _ body: () async throws -> T) async rethrows -> T {
        guard let sink else { return try await body() }
        var timings = PhaseTimings()
        let start = timings.start()
        defer { sink(timings.record(phase, since: start).line) }
        return try await body()
    }
}
