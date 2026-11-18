import Foundation

/// Events the guest's input dispatcher has yet to send on, read between emulator text runs: the emulator's gRPC endpoint answers before the guest takes the keys.
enum AndroidKeyBacklog {
    /// Filtered on the device, so the dump's recent key events, which spell what was typed, never cross adb.
    static let script = "dumpsys input | grep 'InboundQueue:'"
    static let pollInterval: Duration = .milliseconds(50)
    static let minPause: Duration = .milliseconds(20)
    static let maxPause: Duration = .milliseconds(500)
    /// The dispatcher drops a key that has waited 10 s, so a run still queued by then would not land.
    static let limit: Duration = .seconds(10)
    /// When the backlog cannot be read: long enough for the guest to read one run off its kernel buffer.
    static let blindPause: Duration = .milliseconds(300)

    /// The inbound queue's length: 0 for `<empty>`, nil when the line is missing or unreadable.
    static func queued(in output: String) -> Int? {
        guard let line = output.split(whereSeparator: \.isNewline).first(where: { $0.contains("InboundQueue:") }) else { return nil }
        let value = line.split(separator: ":", maxSplits: 1).last.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        if value == "<empty>" { return 0 }
        guard value.hasPrefix("length="), let length = Int(value.dropFirst("length=".count)), length >= 0 else { return nil }
        return length
    }

    /// The queue's time to drain at the rate seen since the last read, else one poll interval, so a slow app is read a few times a run.
    static func pause(queued: Int, since last: (queued: Int, pause: Duration)?) -> Duration {
        guard let last, last.queued > queued, last.pause > .zero else { return pollInterval }
        let perEvent = last.pause / (last.queued - queued)
        return min(maxPause, max(minPause, perEvent * queued))
    }
}
