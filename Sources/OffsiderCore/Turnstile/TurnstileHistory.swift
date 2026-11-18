import CryptoKit
import Darwin
import Foundation

/// What Offsider last saw of Turnstile on one device: the state, when it was first seen and when the widget last passed. It keeps no labels, frames or app content.
public struct TurnstileRecord: Equatable, Sendable {
    public static let version = 1
    public static let maximumBytes = 512
    /// A record, or a pass, this old is dropped.
    public static let lifetime: TimeInterval = 24 * 60 * 60
    /// A date this far ahead of the clock was written by a clock since set back.
    static let clockSlack: TimeInterval = 300

    public var state: TurnstileStatus.State
    /// When Offsider first saw `state`, to the second.
    public var since: Date
    /// When Offsider last saw the widget turn to passed; nil when it never did.
    public var lastPassed: Date?

    public init(state: TurnstileStatus.State, since: Date, lastPassed: Date? = nil) {
        self.state = state
        self.since = since
        self.lastPassed = lastPassed
    }

    /// The record after a read of `state` at `now`; nil when nothing changed, or when a screen with no widget would start one.
    public static func next(previous: TurnstileRecord?, state: TurnstileStatus.State, now: Date) -> TurnstileRecord? {
        let now = second(now)
        let previous = previous?.usable(now: now)
        if previous?.state == state { return nil }
        guard previous != nil || state != .absent else { return nil }
        return TurnstileRecord(state: state, since: now, lastPassed: state == .passed ? now : previous?.lastPassed)
    }

    /// The record as it stands at `now`: nil a day after `since` or when dated ahead of the clock; a pass a day old is forgotten.
    public func usable(now: Date) -> TurnstileRecord? {
        guard Self.isFresh(since, now: now) else { return nil }
        var record = self
        if let lastPassed, !Self.isFresh(lastPassed, now: now) { record.lastPassed = nil }
        return record
    }

    /// `{"v":1,"state":"checkbox","since":"2026-11-18T03:12:44Z","lastPassed":null}`.
    public func encoded() -> Data {
        Data(OrderedJSON.object([
            ("v", .integer(Self.version)),
            ("state", .string(state.rawValue)),
            ("since", .string(ProcessStamp.timestamp(since))),
            ("lastPassed", .optional(lastPassed) { .string(ProcessStamp.timestamp($0)) }),
        ]).rendered(compact: true).utf8)
    }

    /// Nil for another version, an unknown state or a missing date; unknown keys are ignored.
    public init?(data: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (object["v"] as? NSNumber)?.intValue == Self.version,
              let state = (object["state"] as? String).flatMap(TurnstileStatus.State.init(rawValue:)),
              let since = (object["since"] as? String).flatMap(ProcessStamp.date(fromTimestamp:)) else {
            return nil
        }
        let passed = object["lastPassed"] as? String
        guard passed == nil || passed.flatMap(ProcessStamp.date(fromTimestamp:)) != nil else { return nil }
        self.init(state: state, since: since, lastPassed: passed.flatMap(ProcessStamp.date(fromTimestamp:)))
    }

    /// `date` to the whole second, as the file keeps it.
    public static func second(_ date: Date) -> Date {
        Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.down))
    }

    static func isFresh(_ date: Date, now: Date) -> Bool {
        let age = now.timeIntervalSince(date)
        return age < lifetime && age > -clockSlack
    }
}

/// One small 0600 file per device under the private directory's `turnstile/`, written only when the state changes; nothing here throws, since losing it costs only the history.
public struct TurnstileHistory: Sendable {
    public static let directoryName = "turnstile"
    static let suffix = ".json"
    static let lockName = ".lock"

    let root: @Sendable () -> String
    public let now: @Sendable () -> Date

    @TaskLocal public static var current = TurnstileHistory()

    /// `root` is read only when a record is, so binding another store never touches the live directory.
    public init(root: @escaping @Sendable () -> String = { OffsiderPrivateDirectory.root }, now: @escaping @Sendable () -> Date = { Date() }) {
        self.root = root
        self.now = now
    }

    /// `<first 16 hex of SHA-256 of "platform:device">.json`, so no id reaches a file name.
    public static func fileName(platform: DevicePlatform, device: String) -> String {
        let digest = SHA256.hash(data: Data("\(platform.rawValue):\(device)".utf8))
        return digest.prefix(8).map { unsafe String(format: "%02x", $0) }.joined() + suffix
    }

    /// The device's record, or nil; a stale or unreadable one is removed. Creates nothing.
    public func record(platform: DevicePlatform, device: String) -> TurnstileRecord? {
        guard let directory = existingDirectory() else { return nil }
        return read(named: Self.fileName(platform: platform, device: device), in: directory, now: now())
    }

    /// Feeds one read of `state`: writes only when it changed, under the directory's lock, and returns the record as it now stands, saved or not.
    @discardableResult
    public func note(_ state: TurnstileStatus.State, platform: DevicePlatform, device: String) -> TurnstileRecord {
        let now = self.now()
        let name = Self.fileName(platform: platform, device: device)
        let previous = existingDirectory().flatMap { read(named: name, in: $0, now: now) }
        guard let next = TurnstileRecord.next(previous: previous, state: state, now: now) else {
            return previous ?? TurnstileRecord(state: state, since: TurnstileRecord.second(now))
        }
        guard let directory = try? OffsiderPrivateDirectory.ensureSubdirectory(Self.directoryName, root: root()) else { return next }
        let written = try? locked(directory) { () -> TurnstileRecord in
            // Another command may have read the device since.
            let current = read(named: name, in: directory, now: now)
            guard let update = TurnstileRecord.next(previous: current, state: state, now: now) else { return current ?? next }
            try OffsiderPrivateDirectory.writeAtomically(update.encoded(), named: name, in: directory)
            sweep(directory, keeping: name)
            return update
        }
        return written ?? next
    }

    private func existingDirectory() -> String? {
        try? OffsiderPrivateDirectory.existingSubdirectory(Self.directoryName, root: root())
    }

    private func read(named name: String, in directory: String, now: Date) -> TurnstileRecord? {
        guard let data = try? OffsiderPrivateDirectory.readOwnedFile(named: name, in: directory, maxBytes: TurnstileRecord.maximumBytes) else { return nil }
        guard let record = TurnstileRecord(data: data)?.usable(now: now) else {
            OffsiderPrivateDirectory.removeFile(named: name, in: directory)
            return nil
        }
        return record
    }

    /// Removes every other device's record last written a day ago, so a device nothing reads again keeps none.
    private func sweep(_ directory: String, keeping name: String) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory) else { return }
        // File times are wall-clock times, whatever clock the history runs on.
        let now = Date()
        for other in names where other.hasSuffix(Self.suffix) && !other.hasPrefix(".") && other != name {
            var info = stat()
            guard unsafe lstat((directory as NSString).appendingPathComponent(other), &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { continue }
            let modified = Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec))
            if now.timeIntervalSince(modified) >= TurnstileRecord.lifetime {
                OffsiderPrivateDirectory.removeFile(named: other, in: directory)
            }
        }
    }

    /// Holds the directory's `flock` for `body`, which the kernel drops if the process dies.
    private func locked<T>(_ directory: String, _ body: () throws -> T) throws -> T {
        let lockPath = (directory as NSString).appendingPathComponent(Self.lockName)
        let descriptor = try OffsiderPrivateDirectory.openPrivateFile(lockPath)
        defer { Darwin.close(descriptor) }
        while flock(descriptor, LOCK_EX) != 0 {
            guard errno == EINTR else { throw PrivateDirectoryError(.system(operation: "flock", code: errno), path: lockPath) }
        }
        defer { flock(descriptor, LOCK_UN) }
        return try body()
    }
}
