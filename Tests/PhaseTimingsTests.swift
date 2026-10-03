import Foundation
import Synchronization
import Testing
import OffsiderCore

@Suite("Phase timings")
struct PhaseTimingsTests {
    private final class FakeClock: Sendable {
        private let ticks: Mutex<[UInt64]>

        init(_ ticks: [UInt64]) {
            self.ticks = Mutex(ticks)
        }

        func now() -> UInt64 {
            ticks.withLock { $0.removeFirst() }
        }
    }

    @Test("Each phase prints one line in the documented format, rounded to whole milliseconds")
    func formatsPhaseLines() {
        let clock = FakeClock([0, 12_400_000, 20_000_000, 21_600_000])
        var timings = PhaseTimings(now: clock.now)

        let simulatorSetStart = timings.start()
        timings.record("simulator-set", since: simulatorSetStart)
        let captureStart = timings.start()
        timings.record("capture", since: captureStart)

        #expect(timings.lines == [
            "offsider timing: simulator-set 12 ms",
            "offsider timing: capture 2 ms",
        ])
    }

    @Test("A clock that runs backwards records zero rather than wrapping")
    func backwardsClockRecordsZero() {
        let clock = FakeClock([5_000_000, 1_000_000])
        var timings = PhaseTimings(now: clock.now)

        let start = timings.start()
        let phase = timings.record("total", since: start)

        #expect(phase.line == "offsider timing: total 0 ms")
    }

    @Test("Timings are on only when OFFSIDER_TIMINGS is exactly 1")
    func environmentGate() {
        #expect(PhaseTimings.isEnabled(environment: ["OFFSIDER_TIMINGS": "1"]))
        #expect(!PhaseTimings.isEnabled(environment: [:]))
        #expect(!PhaseTimings.isEnabled(environment: ["OFFSIDER_TIMINGS": "0"]))
        #expect(!PhaseTimings.isEnabled(environment: ["OFFSIDER_TIMINGS": "true"]))
        #expect(!PhaseTimings.isEnabled(environment: ["OFFSIDER_TIMINGS": ""]))
    }
}
