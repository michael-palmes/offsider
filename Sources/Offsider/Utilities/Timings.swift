import Foundation
import OffsiderAndroid
import OffsiderCore

/// Prints `offsider timing: <phase> <n> ms` on stderr as each phase ends, only when `OFFSIDER_TIMINGS=1`.
enum Timings {
    static let isEnabled = PhaseTimings.isEnabled()

    /// The same lines from Android code, which cannot see this enum.
    static let android: AndroidTiming = isEnabled
        ? .printing { line in FileHandle.standardError.write(Data((line + "\n").utf8)) }
        : .disabled

    private static let processStart = PhaseTimings.monotonicNanoseconds()

    static func measure<T>(
        _ phase: String,
        isolation: isolated (any Actor)? = #isolation,
        _ body: () async throws -> T
    ) async rethrows -> T {
        guard isEnabled else {
            return try await body()
        }
        var timings = PhaseTimings()
        let start = timings.start()
        defer { emit(timings.record(phase, since: start)) }
        return try await body()
    }

    static func measure<T>(_ phase: String, _ body: () throws -> T) rethrows -> T {
        guard isEnabled else {
            return try body()
        }
        var timings = PhaseTimings()
        let start = timings.start()
        defer { emit(timings.record(phase, since: start)) }
        return try body()
    }

    /// Starts the total clock and prints the total line at exit, including `Darwin.exit` paths.
    static func installTotal() {
        guard isEnabled else { return }
        _ = processStart
        atexit {
            var timings = PhaseTimings()
            Timings.emit(timings.record("total", since: Timings.processStart))
        }
    }

    private static func emit(_ phase: PhaseTimings.Phase) {
        FileHandle.standardError.write(Data((phase.line + "\n").utf8))
    }
}
