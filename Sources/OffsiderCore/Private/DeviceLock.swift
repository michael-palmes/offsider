import Darwin
import Foundation

/// The canonical device a lock guards: an uppercased iOS UDID or an Android serial.
public struct DeviceLockKey: Hashable, Sendable {
    public let platform: DevicePlatform
    public let id: String

    public init(platform: DevicePlatform, id: String) {
        self.platform = platform
        self.id = id
    }

    public var fileName: String { "\(platform.rawValue)-\(id).lock" }
}

/// Who holds a device, as its lock file records it.
public struct DeviceLockHolder: Equatable, Sendable {
    public let pid: Int32
    public let command: String
    public let startedAt: Date?

    public init(pid: Int32, command: String, startedAt: Date?) {
        self.pid = pid
        self.command = command
        self.startedAt = startedAt
    }

    /// The lock file's `pid=`, `command=` and `started=` lines; nil until the holder has written its pid.
    public static func parse(_ text: String) -> DeviceLockHolder? {
        var fields: [Substring: Substring] = [:]
        for line in text.split(separator: "\n") {
            guard let separator = line.firstIndex(of: "=") else { continue }
            fields[line[..<separator]] = line[line.index(after: separator)...]
        }
        guard let pid = fields["pid"].flatMap({ Int32($0) }), pid > 0 else { return nil }
        let started = fields["started"].flatMap { TimeInterval($0) }.map { Date(timeIntervalSince1970: $0) }
        return DeviceLockHolder(pid: pid, command: fields["command"].map(String.init) ?? "", startedAt: started)
    }

    var fileContents: String {
        "pid=\(pid)\ncommand=\(command)\nstarted=\(Int((startedAt ?? Date()).timeIntervalSince1970))\n"
    }
}

/// Another Offsider command holds the device; nothing was sent.
public struct DeviceBusy: Error, Equatable, Sendable {
    public let device: String
    public let command: String
    public let holder: DeviceLockHolder?
    /// The `--wait-lock` bound that ran out, nil when the claim did not wait.
    public let waited: Duration?
    public let now: Date

    public init(device: String, command: String, holder: DeviceLockHolder?, waited: Duration?, now: Date = Date()) {
        self.device = device
        self.command = command
        self.holder = holder
        self.waited = waited
        self.now = now
    }
}

extension DeviceBusy: OffsiderFailure {
    public var reason: FailureReason { .deviceBusy }

    public var failureMessage: String {
        let who: String
        if let holder {
            var detail = holder.command.isEmpty ? "offsider" : "offsider \(holder.command)"
            if let started = holder.startedAt {
                detail += ", started \(max(0, Int(now.timeIntervalSince(started)))) s ago"
            }
            who = "pid \(holder.pid) (\(detail))"
        } else {
            who = "another Offsider command"
        }
        if let waited {
            return "Device \(device) is still in use by \(who) after waiting \(Self.seconds(waited)) s. Retry when it finishes, or pass a longer --wait-lock <seconds>."
        }
        return "Device \(device) is in use by \(who). Retry when it finishes, or pass --wait-lock <seconds>."
    }

    public var hint: String? { "offsider \(command) ... --wait-lock 30" }

    private static func seconds(_ duration: Duration) -> String {
        let value = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
        return value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
    }
}

/// An exclusive `flock` on one device's file under `locks/`; the kernel drops it when the descriptor closes, even on SIGKILL.
public final class DeviceLock: @unchecked Sendable {
    public static let pollInterval: Duration = .milliseconds(50)

    public let key: DeviceLockKey
    public let path: String
    private var descriptor: Int32

    private init(key: DeviceLockKey, path: String, descriptor: Int32) {
        self.key = key
        self.path = path
        self.descriptor = descriptor
    }

    deinit { release() }

    /// Fails at once with `DeviceBusy` when held, or polls without blocking until `wait` runs out.
    public static func acquire(
        _ key: DeviceLockKey,
        command: String,
        wait: Duration?,
        root: String = OffsiderPrivateDirectory.root,
        now: @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now },
        sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) async throws -> DeviceLock {
        let directory = try OffsiderPrivateDirectory.ensureSubdirectory(OffsiderPrivateDirectory.locksDirectoryName, root: root)
        let path = (directory as NSString).appendingPathComponent(key.fileName)
        let descriptor = try OffsiderPrivateDirectory.openPrivateFile(path)
        let deadline = wait.map { now() + $0 }
        do {
            while !(try tryLock(descriptor, path: path)) {
                guard let deadline, now() < deadline else {
                    throw DeviceBusy(device: key.id, command: command, holder: readHolder(descriptor), waited: wait)
                }
                try await sleep(min(pollInterval, max(.zero, deadline - now())))
            }
            let holder = DeviceLockHolder(pid: getpid(), command: command, startedAt: Date())
            let bytes = Array(holder.fileContents.utf8)
            guard ftruncate(descriptor, 0) == 0, pwrite(descriptor, bytes, bytes.count, 0) == bytes.count else {
                throw PrivateDirectoryError(.system(operation: "write", code: errno), path: path)
            }
            return DeviceLock(key: key, path: path, descriptor: descriptor)
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    /// Idempotent; the file stays, since unlinking a `flock` file races with the next opener, but is emptied first so no reader sees a stale holder.
    public func release() {
        guard descriptor >= 0 else { return }
        _ = ftruncate(descriptor, 0)
        Darwin.close(descriptor)
        descriptor = -1
    }

    /// The live Offsider command holding `key`, read without taking the lock: a shared `flock` probe would make a concurrent acquirer fail.
    /// The pid must be alive, an `offsider` executable, and have started before the lock was taken, so a reused pid never counts.
    public static func currentHolder(
        _ key: DeviceLockKey,
        root: String = OffsiderPrivateDirectory.root,
        isOffsider: (Int32) -> Bool = DeviceLock.isOffsiderProcess,
        startTime: (Int32) -> Date? = { ProcessStartTime.date(of: $0) }
    ) -> DeviceLockHolder? {
        let path = ((root as NSString).appendingPathComponent(OffsiderPrivateDirectory.locksDirectoryName) as NSString).appendingPathComponent(key.fileName)
        let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        defer { Darwin.close(descriptor) }
        guard let holder = readHolder(descriptor),
              kill(holder.pid, 0) == 0 || errno == EPERM,
              isOffsider(holder.pid) else { return nil }
        if let started = holder.startedAt, let processStart = startTime(holder.pid), processStart > started.addingTimeInterval(1) {
            return nil
        }
        return holder
    }

    /// The executable's file name is `offsider`.
    public static func isOffsiderProcess(_ pid: Int32) -> Bool {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return false }
        let path = String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return (path as NSString).lastPathComponent == "offsider"
    }

    private static func tryLock(_ descriptor: Int32, path: String) throws -> Bool {
        while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            if errno == EINTR { continue }
            if errno == EWOULDBLOCK { return false }
            throw PrivateDirectoryError(.system(operation: "flock", code: errno), path: path)
        }
        return true
    }

    private static func readHolder(_ descriptor: Int32) -> DeviceLockHolder? {
        var buffer = [UInt8](repeating: 0, count: 256)
        let count = pread(descriptor, &buffer, buffer.count, 0)
        guard count > 0 else { return nil }
        return DeviceLockHolder.parse(String(decoding: buffer.prefix(count), as: UTF8.self))
    }
}

extension DeviceBusy: LocalizedError, CustomStringConvertible {
    public var errorDescription: String? { failureMessage }
    public var description: String { failureMessage }
}
