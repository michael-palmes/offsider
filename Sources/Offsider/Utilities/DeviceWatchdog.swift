import Foundation
import OffsiderCore

/// Ends the process when a device read hangs past a command's own bound, which an in-loop deadline cannot catch on a blocked main actor.
final class DeviceWatchdog: @unchecked Sendable {
    static let grace: TimeInterval = 15
    /// The bound for routing and `prepare`: a cold emulator's adb server can pass the grace alone.
    static let setupBound: TimeInterval = 45
    /// The bound for starting an emulator's helper: another command's start under the lock (45 s), its broker's hello (35 s), then a direct start (30 s) before the uiautomator fallback.
    static let treeStartBound: TimeInterval = 110
    /// The bound for one read of a screen or tree: 30 s with the grace, past the slowest healthy read with every hit-test.
    static let readBound: TimeInterval = 15

    private let queue = DispatchQueue(label: "offsider.device-watchdog")
    private let grace: TimeInterval
    private let setupBound: TimeInterval
    private let readBound: TimeInterval
    private let treeStartBound: TimeInterval
    private let fire: @Sendable (String) -> Void
    private var timer: DispatchSourceTimer?
    private var beforeFire: (@Sendable () -> Void)?

    /// What a watchdog made without its own `fire` does when it goes off.
    enum Action: Sendable {
        /// Writes the message to stderr and carries on, as code run in-process, such as a test, should.
        case report
        /// Reports and ends the process.
        case exitProcess

        var fire: @Sendable (String) -> Void {
            switch self {
            case .report: DeviceWatchdog.report
            case .exitProcess: DeviceWatchdog.exitProcess
            }
        }
    }

    /// `OffsiderCommand.withCLIDefaults` runs every command under `exitProcess`.
    @TaskLocal static var defaultAction = Action.report

    /// What this watchdog does when it goes off; nil when it was made with its own `fire`.
    let action: Action?

    init(
        grace: TimeInterval = DeviceWatchdog.grace,
        setupBound: TimeInterval = DeviceWatchdog.setupBound,
        readBound: TimeInterval = DeviceWatchdog.readBound,
        treeStartBound: TimeInterval = DeviceWatchdog.treeStartBound,
        fire: (@Sendable (String) -> Void)? = nil
    ) {
        self.grace = grace
        self.setupBound = setupBound
        self.readBound = readBound
        self.treeStartBound = treeStartBound
        if let fire {
            action = nil
            self.fire = fire
        } else {
            action = Self.defaultAction
            self.fire = Self.defaultAction.fire
        }
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
                self.beforeFire?()
                self.fire(message)
            }
            timer = source
            source.resume()
        }
    }

    /// Runs on the watchdog's own queue just before it goes off, which may end the process; for what must not stay on the device.
    func beforeFiring(_ body: @escaping @Sendable () -> Void) {
        queue.sync { beforeFire = body }
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

    /// Runs routing, `prepare` or opening a session with the watchdog armed for the setup bound.
    func guardingSetup<T>(device: String, _ body: () async throws -> T) async rethrows -> T {
        try await guarding(bound: setupBound, device: device, body)
    }

    private static func hasOwnLimits(_ device: DeviceID) -> Bool {
        device.isPhysicalAndroidDevice || device.isPhysicalIOSDevice
    }

    /// Runs `body` on a simulator or emulator armed for `bound` plus the grace; a physical device has limits of its own, and a first iPhone read can build the runner.
    func guarding<T>(bound: TimeInterval, of device: DeviceID, _ body: () async throws -> T) async rethrows -> T {
        guard !Self.hasOwnLimits(device) else { return try await body() }
        return try await guarding(bound: bound, device: device.rawValue, body)
    }

    /// Runs one read armed for `readBound` plus `extra`, on a simulator or emulator only.
    func guardingRead<T>(of device: DeviceID, extra: TimeInterval = 0, _ body: () async throws -> T) async rethrows -> T {
        try await guarding(bound: readBound + extra, of: device, body)
    }

    /// Runs `body` armed for the setup bound until it calls `ready` (after routing and `prepare`), then for `bound`; a physical device runs unarmed, as above.
    func guarding<T>(setupThen bound: TimeInterval, of device: DeviceID, _ body: (_ ready: @escaping @Sendable () -> Void) async throws -> T) async rethrows -> T {
        try await guarding(bound: setupBound, of: device) {
            try await body { [self] in
                guard !Self.hasOwnLimits(device) else { return }
                arm(bound: bound, device: device.rawValue)
            }
        }
    }

    /// Starts what an emulator's tree reads go through, outside any shorter bound, so a slow helper reaches its uiautomator fallback; also covers a `--wait-lock` wait, since the start claims the device. A phone's read has no bound to outrun.
    @MainActor
    func guardingTreeStart(on route: DeviceRouter.Route, claims: DeviceClaims = .current) async throws {
        guard let reader = route.backend as? any MaskTreeReading, !Self.hasOwnLimits(route.device) else { return }
        try await guarding(bound: treeStartBound + claims.longestWait, of: route.device) {
            try await reader.prepareMaskTree(for: route.device)
        }
    }

    /// One read of an input command, whose helper may not have started yet.
    func guardingInputRead<T>(of device: DeviceID, _ body: () async throws -> T) async rethrows -> T {
        try await guardingRead(of: device, extra: device.platform == .android ? treeStartBound : 0, body)
    }

    static func message(seconds: TimeInterval, device: String) -> String {
        "Error: the device did not answer within \(String(format: "%g", seconds.rounded())) s. The simulator or emulator may be hung: run `offsider doctor --device \(device)`, or restart the device."
    }

    @Sendable static func exitProcess(_ message: String) {
        ErrorReporter.exitUnresponsive(message)
    }

    @Sendable static func report(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}
