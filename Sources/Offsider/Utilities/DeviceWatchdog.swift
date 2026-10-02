import Foundation

/// Ends the process when a device read hangs past a command's own bound, which an in-loop deadline cannot catch on a blocked main actor.
final class DeviceWatchdog: @unchecked Sendable {
    static let grace: TimeInterval = 15

    private let queue = DispatchQueue(label: "offsider.device-watchdog")
    private let grace: TimeInterval
    private let fire: @Sendable (String) -> Void
    private var timer: DispatchSourceTimer?

    init(grace: TimeInterval = DeviceWatchdog.grace, fire: @escaping @Sendable (String) -> Void = DeviceWatchdog.exitProcess) {
        self.grace = grace
        self.fire = fire
    }

    /// Arms for `bound` plus the grace, replacing any earlier arming.
    func arm(bound: TimeInterval, device: String) {
        let limit = max(0, bound) + grace
        let message = Self.message(seconds: limit, device: device)
        queue.sync {
            timer?.cancel()
            let source = DispatchSource.makeTimerSource(queue: queue)
            source.schedule(deadline: .now() + limit)
            source.setEventHandler { [weak self, weak source] in
                guard let self, let source, self.timer === source, !source.isCancelled else { return }
                self.timer = nil
                source.cancel()
                self.fire(message)
            }
            timer = source
            source.resume()
        }
    }

    func disarm() {
        queue.sync {
            timer?.cancel()
            timer = nil
        }
    }

    var isArmed: Bool { queue.sync { timer != nil } }

    /// Runs `body` with the watchdog armed for `bound` seconds plus the grace.
    func guarding<T>(bound: TimeInterval, device: String, _ body: () async throws -> T) async rethrows -> T {
        arm(bound: bound, device: device)
        defer { disarm() }
        return try await body()
    }

    static func message(seconds: TimeInterval, device: String) -> String {
        "Error: the device did not answer within \(String(format: "%g", seconds.rounded())) s. The simulator or emulator may be hung: run `offsider doctor --device \(device)`, or restart the device."
    }

    @Sendable static func exitProcess(_ message: String) {
        FileHandle.standardError.write(Data("\(message)\n".utf8))
        exit(1)
    }
}
