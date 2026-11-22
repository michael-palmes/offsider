import CryptoKit
import Darwin
import Foundation
import os

/// The audit trail of physical-device commands: `device-audit.log` in `~/.config/offsider`, one JSON line per record, each carrying the SHA-256 of the line before it.
public struct AuditTrail: Sendable {
    public static let fileName = "device-audit.log"
    public static let rotatedName = "device-audit.log.1"
    public static let maximumBytes = 5 * 1024 * 1024
    /// The `prev` of the first line ever written.
    public static let genesis = String(repeating: "0", count: 64)
    public static let subsystem = "com.mpalmes.offsider"
    public static let category = "device-audit"
    /// What an administrator passes to `log show --predicate`.
    public static let logPredicate = "subsystem == \"\(subsystem)\" AND category == \"\(category)\""
    public static let defaultLast = 20
    public static let lastRange = 1...1000

    /// What every record of one process shares.
    public struct Stamp: Sendable {
        public var version: String
        public var pid: Int32
        public var session: AuditRecord.Session?
        public var command: String?
        public var milliseconds: Int?

        public init(version: String, pid: Int32, session: AuditRecord.Session? = nil, command: String? = nil, milliseconds: Int? = nil) {
            self.version = version
            self.pid = pid
            self.session = session
            self.command = command
            self.milliseconds = milliseconds
        }
    }

    /// Nil when the account has no home folder: nothing is written, and the mirror still gets each record.
    public let directory: UserConfigDirectory?
    public var maximumBytes: Int
    public var now: @Sendable () -> Date
    public var stamp: @Sendable () -> Stamp
    /// The unified log in the CLI; tests collect records instead.
    public var mirror: @Sendable (AuditRecord) -> Void
    /// Whether managed policy is in force, for the events the allow-list store writes.
    public var managed: @Sendable () -> Bool
    /// Told once per write that fails; the command itself carries on.
    public var problem: @Sendable (String) -> Void

    public init(
        directory: UserConfigDirectory?,
        maximumBytes: Int = AuditTrail.maximumBytes,
        now: @escaping @Sendable () -> Date = { Date() },
        stamp: @escaping @Sendable () -> Stamp,
        mirror: @escaping @Sendable (AuditRecord) -> Void = { _ in },
        managed: @escaping @Sendable () -> Bool = { false },
        problem: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.directory = directory
        self.maximumBytes = maximumBytes
        self.now = now
        self.stamp = stamp
        self.mirror = mirror
        self.managed = managed
        self.problem = problem
    }

    /// The file's path, for messages.
    public var path: String {
        directory.map { Self.path(in: $0, name: Self.fileName) } ?? "~/.config/offsider/\(Self.fileName)"
    }

    static func path(in directory: UserConfigDirectory, name: String) -> String {
        ((directory.home as NSString).appendingPathComponent(UserConfigDirectory.configName) as NSString)
            .appendingPathComponent(UserConfigDirectory.offsiderName + "/" + name)
    }

    /// Writes one line per event and mirrors each; a write that fails is reported through `problem` and never thrown.
    public func record(_ events: [AuditEvent]) {
        guard !events.isEmpty else { return }
        let stamp = stamp()
        let time = now()
        let records = events.map {
            AuditRecord($0, time: time, version: stamp.version, pid: stamp.pid, session: stamp.session, command: stamp.command, milliseconds: stamp.milliseconds)
        }
        do {
            try append(records)
        } catch {
            problem("\(error)")
        }
        records.forEach(mirror)
    }

    // MARK: - Writing

    func append(_ records: [AuditRecord]) throws {
        guard let directory, !records.isEmpty else { return }
        let folder = try directory.existing() ?? directory.ensure()
        let target = (folder as NSString).appendingPathComponent(Self.fileName)
        let rotated = (folder as NSString).appendingPathComponent(Self.rotatedName)
        for _ in 0..<Self.openAttempts {
            if try appendOnce(records, to: target, rotated: rotated, uid: directory.uid) { return }
        }
        throw PrivateDirectoryError(.system(operation: "rotate", code: EAGAIN), path: target)
    }

    /// False when the file was rotated or replaced while this call waited for it, so the caller opens it again.
    private func appendOnce(_ records: [AuditRecord], to target: String, rotated: String, uid: uid_t) throws -> Bool {
        let descriptor = unsafe Darwin.open(target, O_RDWR | O_APPEND | O_CREAT | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw PrivateDirectoryError(.system(operation: "open", code: errno), path: target) }
        defer { Darwin.close(descriptor) }
        let started = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            let waited = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - started
            guard errno == EINTR || (errno == EWOULDBLOCK && waited < Self.lockWaitNanoseconds) else {
                throw PrivateDirectoryError(.system(operation: "flock", code: errno), path: target)
            }
            if errno == EWOULDBLOCK { usleep(waited < 20_000_000 ? 100 : 1000) }
        }
        var info = stat()
        guard unsafe fstat(descriptor, &info) == 0 else { throw PrivateDirectoryError(.system(operation: "fstat", code: errno), path: target) }
        guard (info.st_mode & S_IFMT) == S_IFREG, info.st_uid == uid else { throw PrivateDirectoryError(.unsafeFile, path: target) }
        var named = stat()
        guard unsafe lstat(target, &named) == 0, named.st_ino == info.st_ino, named.st_dev == info.st_dev else { return false }
        if info.st_mode & (S_IRWXG | S_IRWXO) != 0 { fchmod(descriptor, S_IRUSR | S_IWUSR) }

        let size = Int(info.st_size)
        var previous: String
        var needsNewline = false
        if size == 0 {
            previous = Self.lastLineHash(atPath: rotated, uid: uid) ?? Self.genesis
        } else {
            let tail = try Self.tail(of: descriptor, size: size, path: target)
            needsNewline = tail.last != UInt8(ascii: "\n")
            previous = Self.hash(Self.lastLine(in: tail))
        }
        var text = needsNewline ? "\n" : ""
        for record in records {
            let line = record.line(prev: previous)
            previous = Self.hash(Data(line.utf8))
            text += line + "\n"
        }
        let data = Data(text.utf8)
        if size > 0, size + data.count > maximumBytes {
            guard rename(target, rotated) == 0 else { throw PrivateDirectoryError(.system(operation: "rename", code: errno), path: target) }
            return false
        }
        let written = unsafe data.withUnsafeBytes { unsafe Darwin.write(descriptor, $0.baseAddress, $0.count) }
        guard written == data.count else { throw PrivateDirectoryError(.system(operation: "write", code: errno), path: target) }
        return true
    }

    static let tailBytes = AuditRecord.Shape.maximumLineBytes * 2
    /// A writer holds the lock for microseconds; one that is stuck costs a command this long and no more.
    static let lockWaitNanoseconds: UInt64 = 250_000_000
    /// Each rotation by another writer costs one more open.
    static let openAttempts = 8

    private static func tail(of descriptor: Int32, size: Int, path: String) throws -> Data {
        let count = min(size, tailBytes)
        var buffer = [UInt8](repeating: 0, count: count)
        let read = unsafe buffer.withUnsafeMutableBytes { unsafe pread(descriptor, $0.baseAddress, count, off_t(size - count)) }
        guard read == count else { throw PrivateDirectoryError(.system(operation: "pread", code: errno), path: path) }
        return Data(buffer)
    }

    /// The bytes after the last newline that is not the final byte.
    static func lastLine(in tail: Data) -> Data {
        let body = tail.last == UInt8(ascii: "\n") ? tail.dropLast() : tail[...]
        guard let cut = body.lastIndex(of: UInt8(ascii: "\n")) else { return Data(body) }
        return Data(body[body.index(after: cut)...])
    }

    static func hash(_ line: Data) -> String {
        AuditRecord.hex(SHA256.hash(data: line))
    }

    private static func lastLineHash(atPath path: String, uid: uid_t) -> String? {
        let descriptor = unsafe Darwin.open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else { return nil }
        defer { Darwin.close(descriptor) }
        var info = stat()
        guard unsafe fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_uid == uid, info.st_size > 0 else { return nil }
        guard let tail = try? tail(of: descriptor, size: Int(info.st_size), path: path) else { return nil }
        return hash(lastLine(in: tail))
    }

    // MARK: - Reading

    /// What `doctor` reports about the file itself.
    public enum FileState: Equatable, Sendable {
        /// No record has been written on this Mac.
        case none
        case safe(bytes: Int)
        /// Group or other users can read it; the next record written tightens it.
        case readableByOthers
        /// Not a regular file of this user's, or its folder is unsafe, so nothing is written to it.
        case unusable(String)
    }

    public enum Chain: Equatable, Sendable {
        case none
        case intact(lines: Int)
        /// The line whose `prev` does not match the line before it, or that cannot be read.
        case broken(file: String, line: Int)
        case unreadable(String)
    }

    public func fileState() -> FileState {
        guard let directory else { return .none }
        let folder: String?
        do {
            folder = try directory.existing()
        } catch {
            return .unusable("\(error)")
        }
        guard let folder else { return .none }
        let target = (folder as NSString).appendingPathComponent(Self.fileName)
        var info = stat()
        guard unsafe lstat(target, &info) == 0 else {
            return errno == ENOENT ? .none : .unusable(unsafe "\(Self.fileName): \(String(cString: strerror(errno)))")
        }
        guard (info.st_mode & S_IFMT) == S_IFREG else { return .unusable("\(Self.fileName) is not a regular file") }
        guard info.st_uid == directory.uid else { return .unusable("\(Self.fileName) belongs to another user") }
        guard info.st_mode & (S_IRWXG | S_IRWXO) == 0 else { return .readableByOthers }
        return .safe(bytes: Int(info.st_size))
    }

    private func contents() -> (files: [(name: String, data: Data)], problem: String?) {
        guard let directory else { return ([], nil) }
        let folder: String?
        do {
            folder = try directory.existing()
        } catch {
            return ([], "\(error)")
        }
        guard let folder else { return ([], nil) }
        let rotated = (folder as NSString).appendingPathComponent(Self.rotatedName)
        var files: [(String, Data)] = []
        // Read again when a writer rotated the file between the two reads, so the pair always belongs together.
        for _ in 0..<3 {
            files = []
            let before = Self.identity(rotated)
            for name in [Self.rotatedName, Self.fileName] {
                do {
                    files.append((name, try UntrustedRead.data(atPath: (folder as NSString).appendingPathComponent(name), maxBytes: max(maximumBytes, Self.maximumBytes) + Self.tailBytes)))
                } catch UntrustedRead.Failure.missing {
                    continue
                } catch {
                    return ([], "\(name): \(error)")
                }
            }
            if Self.identity(rotated) == before { break }
        }
        return (files, nil)
    }

    private static func identity(_ path: String) -> UInt64? {
        var info = stat()
        return unsafe lstat(path, &info) == 0 ? UInt64(info.st_ino) : nil
    }

    private static func lines(_ data: Data) -> [Data] {
        data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false).dropLast(data.last == UInt8(ascii: "\n") ? 1 : 0).map { Data($0) }
    }

    private static let prevPrefix = Data("{\"prev\":\"".utf8)

    /// The `prev` a line carries, read from its fixed start so a line from a newer Offsider still links.
    static func prev(of line: Data) -> String? {
        guard line.count >= prevPrefix.count + 65, line.prefix(prevPrefix.count) == prevPrefix else { return nil }
        let start = line.startIndex + prevPrefix.count
        guard line[start + 64] == UInt8(ascii: "\"") else { return nil }
        let text = String(decoding: line[start..<(start + 64)], as: UTF8.self)
        return AuditRecord.Shape.isHash(text) ? text : nil
    }

    /// Follows every link through the kept file and the current one. Lines cut from the end leave no trace here; the unified log copy is the check for that.
    public func verify() -> Chain {
        let (files, problem) = contents()
        if let problem { return .unreadable(problem) }
        guard !files.isEmpty else { return .none }
        var expected: String? = files.count == 1 && files[0].name == Self.fileName ? Self.genesis : nil
        var count = 0
        for file in files {
            for (index, line) in Self.lines(file.data).enumerated() {
                guard let prev = Self.prev(of: line), expected.map({ $0 == prev }) ?? true else { return .broken(file: file.name, line: index + 1) }
                expected = Self.hash(line)
                count += 1
            }
        }
        return .intact(lines: count)
    }

    /// The newest `count` records this build can read, oldest first; `device` keeps one hashed device key's.
    public func last(_ count: Int, device: String? = nil) -> [AuditRecord] {
        let wanted = min(max(count, Self.lastRange.lowerBound), Self.lastRange.upperBound)
        var found: [AuditRecord] = []
        for file in contents().files.reversed() {
            for line in Self.lines(file.data).reversed() {
                guard found.count < wanted else { break }
                if let parsed = AuditRecord.parse(line), device.map({ $0 == parsed.record.device }) ?? true { found.append(parsed.record) }
            }
        }
        return found.reversed()
    }

    // MARK: - The unified log

    private static let logger = Logger(subsystem: subsystem, category: category)

    /// The same fields at notice level, which macOS keeps on disk; the app id is hashed there.
    public static let unifiedLog: @Sendable (AuditRecord) -> Void = { record in
        let session = record.session.map { "\($0.name):\($0.pid)" } ?? "-"
        logger.notice(
            """
            outcome=\(record.outcome.rawValue, privacy: .public) command=\(record.command, privacy: .public) platform=\(record.platform.rawValue, privacy: .public) \
            device=\(record.device, privacy: .public) app=\(record.app ?? "-", privacy: .private(mask: .hash)) exit=\(record.exit.map { String($0) } ?? "-", privacy: .public) \
            reason=\(record.reason ?? "-", privacy: .public) refusal=\(record.refusal ?? "-", privacy: .public) testDevice=\(record.testDevice, privacy: .public) \
            managed=\(record.managed, privacy: .public) ms=\(record.milliseconds.map { String($0) } ?? "-", privacy: .public) \
            expires=\(record.expires.map(ProcessStamp.timestamp) ?? "-", privacy: .public) pins=\(record.pins.map { String($0) } ?? "-", privacy: .public) \
            version=\(record.version, privacy: .public) session=\(session, privacy: .public)
            """
        )
    }
}

/// The physical devices one command reached, gathered as it runs and written once when it ends, from whichever thread ends it.
public final class CommandAudit: @unchecked Sendable {
    /// Failures that mean Offsider's own rules stopped the command on a device it had already routed to.
    public static let refusedReasons: Set<String> = [FailureReason.appNotAllowed.rawValue, FailureReason.guardedControl.rawValue, FailureReason.personRequired.rawValue]

    private struct Entry {
        var event: AuditEvent
        var marked = false
    }

    private let lock = NSLock()
    private var trail: (@Sendable () -> AuditTrail)?
    private var entries: [Entry] = []
    private var finished = false

    public init(trail: (@Sendable () -> AuditTrail)? = nil) {
        self.trail = trail
    }

    /// Built only when a record is written, so a command on a simulator or emulator never makes one.
    public func attach(_ trail: @escaping @Sendable () -> AuditTrail) {
        lock.withLock { self.trail = trail }
    }

    public var isEmpty: Bool {
        lock.withLock { entries.isEmpty }
    }

    private func index(_ platform: DevicePlatform, _ key: String) -> Int? {
        entries.firstIndex { $0.event.platform == platform && $0.event.key == key }
    }

    /// A physical device the gate let this command reach; one entry per device, whatever the number of routes.
    public func note(platform: DevicePlatform, key: String, app: String? = nil, testDevice: Bool, managed: Bool) {
        lock.withLock {
            guard !finished else { return }
            if let found = index(platform, key) {
                if entries[found].event.app == nil { entries[found].event.app = app }
                return
            }
            entries.append(Entry(event: AuditEvent(.ran, platform: platform, key: key, app: app, testDevice: testDevice, managed: managed)))
        }
    }

    /// A physical device, or an app on one, that the gate refused; the command's record reads `refused`.
    public func noteRefusal(platform: DevicePlatform, key: String, code: String, app: String? = nil, testDevice: Bool = false, managed: Bool) {
        lock.withLock {
            guard !finished else { return }
            let found = index(platform, key) ?? {
                entries.append(Entry(event: AuditEvent(.ran, platform: platform, key: key, testDevice: testDevice, managed: managed)))
                return entries.count - 1
            }()
            entries[found].event.refusal = code
            if let app { entries[found].event.app = app }
        }
    }

    /// Names what the command did to a device it reached, in place of `ran`.
    public func mark(_ outcome: AuditRecord.Outcome, platform: DevicePlatform, key: String) {
        lock.withLock {
            guard !finished, let found = index(platform, key) else { return }
            entries[found].event.outcome = outcome
            entries[found].marked = true
        }
    }

    /// Writes now, for an event a long-lived broker must not hold until it ends.
    public func write(_ event: AuditEvent) {
        guard let trail = lock.withLock({ trail }) else { return }
        trail().record([event])
    }

    /// The process is exiting without the command's own end having run, so no exit code is known; a no-op once `finish` has run.
    public func finishEarly() {
        finish(exit: nil, reason: nil)
    }

    /// One record per noted device; later calls write nothing, so the command's end and a watchdog's exit never both write.
    public func finish(exit: Int32?, reason: String?) {
        let (pending, trail): ([Entry], (@Sendable () -> AuditTrail)?) = lock.withLock {
            guard !finished else { return ([], nil) }
            finished = true
            defer { entries = [] }
            return (entries, trail)
        }
        guard !pending.isEmpty, let trail else { return }
        let refusedByReason = exit ?? 1 != 0 && reason.map(Self.refusedReasons.contains) == true
        trail().record(pending.map { entry in
            var event = entry.event
            if !entry.marked, event.refusal != nil || refusedByReason { event.outcome = .refused }
            event.exit = exit
            event.reason = exit == 0 ? nil : reason
            return event
        })
    }
}
