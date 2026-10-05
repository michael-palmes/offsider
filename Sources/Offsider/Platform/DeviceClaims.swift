import Foundation
import OffsiderCore

/// The device locks this process holds; claiming a held device again is a no-op, so `batch` and the Android helper lock once.
@MainActor
final class DeviceClaims {
    nonisolated static let current = DeviceClaims()
    nonisolated static let waitEnvironmentKey = "OFFSIDER_WAIT_LOCK"
    nonisolated static let maximumWait: Double = 600

    /// Recorded in the lock file so a refused command can name the holder.
    var command = "offsider"
    /// `--wait-lock`, in seconds; nil falls back to `OFFSIDER_WAIT_LOCK`, then to failing at once.
    var waitOption: Double?
    var environment: [String: String] = ProcessInfo.processInfo.environment
    var root: () -> String = { OffsiderPrivateDirectory.root }

    private var held: [DeviceLockKey: DeviceLock] = [:]
    private var pending: [DeviceLockKey: Task<DeviceLock, any Error>] = [:]

    nonisolated init() {}

    var heldKeys: Set<DeviceLockKey> { Set(held.keys) }

    func configure(command: String, waitOption: Double?) {
        self.command = command
        self.waitOption = waitOption
    }

    func claim(_ key: DeviceLockKey) async throws {
        if held[key] != nil { return }
        if let task = pending[key] {
            _ = try await task.value
            return
        }
        let command = command
        let wait = try Self.resolveWait(option: waitOption, environment: environment)
        let root = root()
        let task = Task { try await DeviceLock.acquire(key, command: command, wait: wait, root: root) }
        pending[key] = task
        defer { pending[key] = nil }
        let lock = try await Timings.measure("device-lock") { try await task.value }
        held[key] = lock
    }

    func claim(_ device: DeviceID) async throws {
        try await claim(DeviceLockKey(platform: device.platform, id: device.rawValue))
    }

    func releaseAll() {
        for lock in held.values { lock.release() }
        held.removeAll()
    }

    /// `--wait-lock` wins; else `OFFSIDER_WAIT_LOCK`; else no wait.
    nonisolated static func resolveWait(option: Double?, environment: [String: String]) throws -> Duration? {
        if let option {
            return .milliseconds(Int((option * 1000).rounded()))
        }
        guard let raw = environment[waitEnvironmentKey]?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        guard let seconds = Double(raw), seconds.isFinite, (0...maximumWait).contains(seconds) else {
            throw CLIError(
                errorDescription: "\(waitEnvironmentKey) must be a number of seconds from 0 to \(Int(maximumWait)), not \(raw).",
                reason: .usage
            )
        }
        return .milliseconds(Int((seconds * 1000).rounded()))
    }
}

/// A command that can lock the device, so it takes `--wait-lock`; a test checks this list against every command's help.
protocol LockingCommand {
    var waitLock: Double? { get }
}

protocol DeviceOptionCommand: LockingCommand {
    var deviceOption: DeviceOption { get }
}

extension DeviceOptionCommand {
    var waitLock: Double? { deviceOption.waitLock }
}

extension PermissionCommand: LockingCommand {
    var waitLock: Double? { lock.waitLock }
}

extension AppearanceCommand: DeviceOptionCommand {}
extension Assert: DeviceOptionCommand {}
extension Batch: DeviceOptionCommand {}
extension BiometricCommand: DeviceOptionCommand {}
extension Button: DeviceOptionCommand {}
extension ContentSizeCommand: DeviceOptionCommand {}
extension DescribeUI: DeviceOptionCommand {}
extension Drag: DeviceOptionCommand {}
extension Gesture: DeviceOptionCommand {}
extension Key: DeviceOptionCommand {}
extension KeyCombo: DeviceOptionCommand {}
extension KeySequence: DeviceOptionCommand {}
extension OrientationCommand: DeviceOptionCommand {}
extension PostureCommand: DeviceOptionCommand {}
extension RNPrepare: DeviceOptionCommand {}
extension RNOpen: DeviceOptionCommand {}
extension RNLogBoxStatus: DeviceOptionCommand {}
extension RNLogBoxDismiss: DeviceOptionCommand {}
extension Screenshot: DeviceOptionCommand {}
extension Shake: DeviceOptionCommand {}
extension Slider: DeviceOptionCommand {}
extension StatusBarCommand: DeviceOptionCommand {}
extension StayAwakeCommand: DeviceOptionCommand {}
extension Swipe: DeviceOptionCommand {}
extension Tap: DeviceOptionCommand {}
extension Touch: DeviceOptionCommand {}
extension Turnstile: DeviceOptionCommand {}
extension Type: DeviceOptionCommand {}
extension Wait: DeviceOptionCommand {}
extension Wake: DeviceOptionCommand {}
