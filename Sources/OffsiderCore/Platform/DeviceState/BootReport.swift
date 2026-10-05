import Foundation

/// `boot --json`: the emulator, the RAM it sees and its lock state; a failure carries its exit code and error object.
public struct BootReport: Equatable, Sendable {
    public static let schemaVersion = 1
    /// About 2.75 GB: below this a React Native debug build and Metro's bundle leave the device swapping.
    public static let lowMemoryKB = 2_883_584

    public var avd: String
    public var serial: String
    public var alreadyRunning: Bool
    public var grpc: Bool
    public var logPath: String?
    public var memoryMB: Int?
    public var ignored: [String]
    public var lock: LockReport?
    public var error: ErrorPayload?

    public init(
        avd: String, serial: String, alreadyRunning: Bool, grpc: Bool, logPath: String?, memoryMB: Int?, ignored: [String],
        lock: LockReport?, error: ErrorPayload? = nil
    ) {
        self.avd = avd
        self.serial = serial
        self.alreadyRunning = alreadyRunning
        self.grpc = grpc
        self.logPath = logPath
        self.memoryMB = memoryMB
        self.ignored = ignored
        self.lock = lock
        self.error = error
    }

    public var exitCode: OffsiderExitCode { error?.exitCode ?? .success }

    public func jsonLine() -> String {
        OrderedJSON.object([
            ("version", .integer(Self.schemaVersion)),
            ("ok", .bool(error == nil)),
            ("avd", .string(avd)),
            ("serial", .string(serial)),
            ("alreadyRunning", .bool(alreadyRunning)),
            ("grpc", .bool(grpc)),
            ("logPath", .optional(logPath) { .string($0) }),
            ("memoryMB", .optional(memoryMB) { .integer($0) }),
            ("ignored", .array(ignored.map { .string($0) })),
            ("lock", .optional(lock) { DeviceStateReport.lock($0) }),
            ("exitCode", .integer(Int(exitCode.rawValue))),
            ("error", .optional(error) { $0.jsonValue }),
        ]).rendered(compact: true)
    }

    /// The `device_locked` message and hint when the device is set up with a credential and has not been unlocked since boot.
    public static func firstUnlockFailure(avd: String, serial: String, alreadyRunning: Bool, reading: AwakeReading?, lock: LockReport) -> (message: String, hint: String)? {
        guard let reading, reading.awaitsFirstUnlock else { return nil }
        let how = alreadyRunning ? "is running" : "booted"
        return (
            "\(avd) \(how) as \(serial) but is waiting for its first unlock (\(reading.credentialName)); apps cannot start until it is unlocked.",
            lock.unlockHint(deviceID: serial)
        )
    }

    /// A stderr note for an unlocked device whose screen is off or lock screen is up, so input would not reach the app.
    public static func screenNote(avd: String, serial: String, reading: AwakeReading?) -> String? {
        guard let reading, !reading.isUsable else { return nil }
        return "Note: \(avd) is \(reading.screenSummary); run `offsider wake --device \(serial)` before sending input."
    }

    /// A stderr note when the device has less RAM than a React Native debug session needs.
    public static func memoryNote(avd: String, reading: AwakeReading?) -> String? {
        guard let kilobytes = reading?.memTotalKB, kilobytes < lowMemoryKB else { return nil }
        return "Warning: \(avd) has \(memorySummary(kilobytes)) of RAM, which is tight for a React Native debug build. Close it, then run `offsider boot \(avd) --memory 4096`."
    }

    /// `2.0 GB`.
    public static func memorySummary(_ kilobytes: Int) -> String {
        String(format: "%.1f GB", Double(kilobytes) / 1_048_576)
    }
}
