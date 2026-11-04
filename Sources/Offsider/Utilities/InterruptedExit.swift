import Darwin
import Foundation

/// While alive, SIGINT or SIGTERM runs `first` from a fresh task, as a cancelled one may fail its calls, then ends the process as the signal would have; `first` gets `bound` seconds.
@MainActor
final class InterruptedExit {
    nonisolated static let bound: TimeInterval = 3
    private var observers: [SignalObserver] = []
    private var fired = false
    private let bound: TimeInterval

    init(bound: TimeInterval = InterruptedExit.bound, first: @escaping @MainActor () async -> Void, exit: @escaping @Sendable (Int32) -> Void = { Darwin.exit($0) }) {
        self.bound = bound
        observers = [SIGINT, SIGTERM].map { number in
            SignalObserver(signals: [number]) { [weak self] in
                Task { @MainActor in
                    guard let self, !self.fired else { return }
                    self.fired = true
                    DispatchQueue.global().asyncAfter(deadline: .now() + bound) { exit(128 + number) }
                    await first()
                    exit(128 + number)
                }
            }
        }
    }

    /// Once a signal has fired, the work it interrupted waits here rather than report its own error; the exit comes first.
    func holdIfFired() async {
        guard fired else { return }
        try? await Task.sleep(for: .seconds(bound + 1))
    }

    func invalidate() {
        observers.forEach { $0.invalidate() }
        observers = []
    }
}
