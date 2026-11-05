import Darwin
import Foundation

/// While a paste holds the person's clipboard, SIGINT or SIGTERM puts it back first, then ends the process as the signal would have, within `bound` seconds.
@MainActor
final class ClipboardHold {
    nonisolated static let bound: TimeInterval = 3
    private var sources: [DispatchSourceSignal] = []
    private var previous: [(signal: Int32, handler: sig_t?)] = []

    init(bound: TimeInterval = ClipboardHold.bound, restore: @escaping @MainActor () async -> Void, exit: @escaping @Sendable (Int32) -> Void = { Darwin.exit($0) }) {
        for number in [SIGINT, SIGTERM] {
            previous.append((number, signal(number, SIG_IGN)))
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler {
                DispatchQueue.global().asyncAfter(deadline: .now() + bound) { exit(128 + number) }
                Task { @MainActor in
                    await restore()
                    exit(128 + number)
                }
            }
            source.resume()
            sources.append(source)
        }
    }

    /// Hands the signals back to whatever handled them before.
    func end() {
        sources.forEach { $0.cancel() }
        sources.removeAll()
        for (number, handler) in previous {
            signal(number, handler)
        }
        previous.removeAll()
    }
}
