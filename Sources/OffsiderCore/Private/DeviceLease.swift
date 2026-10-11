import Darwin
import Foundation

/// An advisory claim on a device across a session: a label, when it started and when it lapses. No input command reads it.
public struct DeviceLease: Equatable, Sendable {
    public static let labelLengths = 1...80
    public static let minutes = 1...1440
    public static let defaultMinutes = 240

    public let label: String
    public let created: Date
    public let expires: Date
    /// The process that set it, usually the agent's shell.
    public let pid: Int32
    /// The session that set it: the first ancestor of `lease set` that is not a shell or wrapper, such as an agent harness or a terminal's `login`; nil in older lease files.
    public let owner: ProcessIdentity?

    public init(label: String, created: Date, expires: Date, pid: Int32, owner: ProcessIdentity? = nil) {
        self.label = label
        self.created = created
        self.expires = expires
        self.pid = pid
        self.owner = owner
    }

    /// 1 to 80 printable characters, trimmed; nil otherwise.
    public static func validLabel(_ text: String) -> String? {
        let label = text.trimmingCharacters(in: .whitespaces)
        guard labelLengths.contains(label.count), label.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else { return nil }
        return label
    }

    var fileContents: String {
        var text = "label=\(label)\ncreated=\(Int(created.timeIntervalSince1970))\nexpires=\(Int(expires.timeIntervalSince1970))\npid=\(pid)\n"
        if let owner {
            let name = String(owner.name.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) })
            text += "owner=\(owner.pid):\(owner.startTime):\(name)\n"
        }
        return text
    }

    /// `<pid>:<startTime>:<name>`, as `fileContents` writes it.
    static func parseOwner(_ text: Substring) -> ProcessIdentity? {
        let parts = text.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3, let pid = Int32(parts[0]), pid > 0, let startTime = UInt64(parts[1]) else { return nil }
        return ProcessIdentity(pid: pid, startTime: startTime, name: String(parts[2]))
    }

    static func parse(_ text: String) -> DeviceLease? {
        var fields: [Substring: Substring] = [:]
        for line in text.split(separator: "\n") {
            guard let separator = line.firstIndex(of: "=") else { continue }
            fields[line[..<separator]] = line[line.index(after: separator)...]
        }
        guard let label = fields["label"].map(String.init).flatMap(validLabel),
              let created = fields["created"].flatMap({ TimeInterval($0) }),
              let expires = fields["expires"].flatMap({ TimeInterval($0) }) else { return nil }
        return DeviceLease(
            label: label,
            created: Date(timeIntervalSince1970: created),
            expires: Date(timeIntervalSince1970: expires),
            pid: fields["pid"].flatMap { Int32($0) } ?? 0,
            owner: fields["owner"].flatMap(parseOwner)
        )
    }
}

/// A leased device: its platform and stable key (an AVD name, a phone serial or an uppercased UDID).
public struct LeasedDevice: Equatable, Sendable {
    public let platform: DevicePlatform
    public let key: String
    public let lease: DeviceLease

    public init(platform: DevicePlatform, key: String, lease: DeviceLease) {
        self.platform = platform
        self.key = key
        self.lease = lease
    }
}

/// Leases under the private directory's `leases/`, one 0600 file per device, changed only under its `flock` on `<name>.lock`; expired ones are removed when read.
public struct DeviceLeaseStore: Sendable {
    static let maxBytes = 4096
    static let suffix = ".lease"

    let root: String

    public init(root: String = OffsiderPrivateDirectory.root) {
        self.root = root
    }

    /// `<platform>-<key>.lease`, with anything outside letters, digits, `.`, `_` and `-` replaced by `_`.
    static func fileName(platform: DevicePlatform, key: String) -> String {
        let safe = String(key.map { $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) ? $0 : "_" })
        return "\(platform.rawValue)-\(safe)\(suffix)"
    }

    private var directory: String {
        (root as NSString).appendingPathComponent(OffsiderPrivateDirectory.leasesDirectoryName)
    }

    public func lease(platform: DevicePlatform, key: String, now: Date = Date()) -> DeviceLease? {
        read(named: Self.fileName(platform: platform, key: key), now: now)
    }

    /// Under the device's lock, passes the live lease to `decide` and writes the lease it returns; a throw from `decide` writes nothing.
    @discardableResult
    public func set(platform: DevicePlatform, key: String, now: Date, _ decide: (DeviceLease?) throws -> DeviceLease) throws -> (previous: DeviceLease?, lease: DeviceLease) {
        let name = Self.fileName(platform: platform, key: key)
        return try locked(name) { directory in
            let previous = liveLease(named: name, now: now, locked: true)
            let lease = try decide(previous)
            try OffsiderPrivateDirectory.writeAtomically(Data(lease.fileContents.utf8), named: name, in: directory)
            return (previous, lease)
        }
    }

    /// The lease that was removed, if a live one existed.
    @discardableResult
    public func remove(platform: DevicePlatform, key: String, now: Date = Date()) -> DeviceLease? {
        let name = Self.fileName(platform: platform, key: key)
        return try? locked(name) { directory in
            let existing = liveLease(named: name, now: now, locked: true)
            unlink((directory as NSString).appendingPathComponent(name))
            return existing
        }
    }

    /// Removes the device's lease only if, read again under its lock, it has expired; a fresh lease that replaced the one a reader saw stays.
    func removeExpired(named name: String, now: Date) {
        _ = try? locked(name) { directory in
            guard let current = parse(named: name), current.expires <= now else { return }
            unlink((directory as NSString).appendingPathComponent(name))
        }
    }

    /// Holds the device's `flock` for `body`; the kernel drops it if the process dies.
    private func locked<T>(_ name: String, _ body: (String) throws -> T) throws -> T {
        let directory = try OffsiderPrivateDirectory.ensureSubdirectory(OffsiderPrivateDirectory.leasesDirectoryName, root: root)
        let lockPath = (directory as NSString).appendingPathComponent(name + ".lock")
        let descriptor = try OffsiderPrivateDirectory.openPrivateFile(lockPath)
        defer { Darwin.close(descriptor) }
        while flock(descriptor, LOCK_EX) != 0 {
            guard errno == EINTR else { throw PrivateDirectoryError(.system(operation: "flock", code: errno), path: lockPath) }
        }
        defer { flock(descriptor, LOCK_UN) }
        return try body(directory)
    }

    /// Every live lease, sorted by file name.
    public func all(now: Date = Date()) -> [LeasedDevice] {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []).filter { $0.hasSuffix(Self.suffix) }.sorted()
        return names.compactMap { name in
            let stem = name.dropLast(Self.suffix.count)
            guard let dash = stem.firstIndex(of: "-"), let platform = DevicePlatform(rawValue: String(stem[..<dash])),
                  let lease = read(named: name, now: now) else { return nil }
            return LeasedDevice(platform: platform, key: String(stem[stem.index(after: dash)...]), lease: lease)
        }
    }

    private func read(named name: String, now: Date) -> DeviceLease? {
        liveLease(named: name, now: now, locked: false)
    }

    /// The unexpired lease; an expired one is removed, straight away when the caller holds the lock and through `removeExpired` otherwise.
    private func liveLease(named name: String, now: Date, locked: Bool) -> DeviceLease? {
        guard let lease = parse(named: name) else { return nil }
        guard lease.expires > now else {
            if locked {
                unlink((directory as NSString).appendingPathComponent(name))
            } else {
                removeExpired(named: name, now: now)
            }
            return nil
        }
        return lease
    }

    private func parse(named name: String) -> DeviceLease? {
        guard let data = try? OffsiderPrivateDirectory.readOwnedFile(named: name, in: directory, maxBytes: Self.maxBytes) else { return nil }
        return DeviceLease.parse(String(decoding: data, as: UTF8.self))
    }
}

extension DeviceStateReport {
    static func leaseObject(_ lease: DeviceLease) -> OrderedJSON {
        .object([
            ("label", .string(lease.label)),
            ("since", .string(ProcessStamp.timestamp(lease.created))),
            ("expiresAt", .string(ProcessStamp.timestamp(lease.expires))),
            ("owner", .optional(lease.owner) { ownerObject($0) }),
        ])
    }

    /// `{"pid":4242,"name":"claude","startedAt":"…"}`: the session that set the lease.
    static func ownerObject(_ owner: ProcessIdentity) -> OrderedJSON {
        .object([
            ("pid", .integer(Int(owner.pid))),
            ("name", .string(owner.name)),
            ("startedAt", .string(ProcessStamp.timestamp(owner.startDate))),
        ])
    }

    /// `lease set` and `lease release`: the lease now, or the one released; null when there was none.
    public static func lease(_ action: String, platform: DevicePlatform, device: String, lease: DeviceLease?) -> String {
        OrderedJSON.object([
            ("version", .integer(1)),
            ("action", .string(action)),
            ("platform", .string(platform.rawValue)),
            ("device", .string(device)),
            ("lease", .optional(lease) { leaseObject($0) }),
        ]).rendered(compact: true)
    }

    /// `lease check`: whether this session may use the device, the lease that decides it, and the error when it may not.
    public static func leaseCheck(platform: DevicePlatform, device: String, lease: DeviceLease?, mine: Bool, ownerEnded: Bool, error: ErrorPayload?) -> String {
        var members: [(String, OrderedJSON)] = [
            ("version", .integer(1)),
            ("action", .string("check")),
            ("platform", .string(platform.rawValue)),
            ("device", .string(device)),
            ("available", .bool(error == nil)),
            ("mine", .bool(mine)),
            ("ownerEnded", .bool(ownerEnded)),
            ("lease", .optional(lease) { leaseObject($0) }),
        ]
        if let error {
            members.append(("error", error.jsonValue))
        }
        return OrderedJSON.object(members).rendered(compact: true)
    }

    public static func leases(_ leases: [LeasedDevice]) -> String {
        OrderedJSON.object([
            ("version", .integer(1)),
            ("leases", .array(leases.map { leased in
                .object([("platform", .string(leased.platform.rawValue)), ("device", .string(leased.key))] + leaseFields(leased.lease))
            })),
        ]).rendered(compact: true)
    }

    private static func leaseFields(_ lease: DeviceLease) -> [(String, OrderedJSON)] {
        guard case .object(let fields) = leaseObject(lease) else { return [] }
        return fields
    }
}
