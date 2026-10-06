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

    public init(label: String, created: Date, expires: Date, pid: Int32) {
        self.label = label
        self.created = created
        self.expires = expires
        self.pid = pid
    }

    /// 1 to 80 printable characters, trimmed; nil otherwise.
    public static func validLabel(_ text: String) -> String? {
        let label = text.trimmingCharacters(in: .whitespaces)
        guard labelLengths.contains(label.count), label.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else { return nil }
        return label
    }

    var fileContents: String {
        "label=\(label)\ncreated=\(Int(created.timeIntervalSince1970))\nexpires=\(Int(expires.timeIntervalSince1970))\npid=\(pid)\n"
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
            pid: fields["pid"].flatMap { Int32($0) } ?? 0
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

/// Leases under the private directory's `leases/`, one 0600 file per device; expired ones are removed when read.
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

    public func save(_ lease: DeviceLease, platform: DevicePlatform, key: String) throws {
        let directory = try OffsiderPrivateDirectory.ensureSubdirectory(OffsiderPrivateDirectory.leasesDirectoryName, root: root)
        try OffsiderPrivateDirectory.writeAtomically(Data(lease.fileContents.utf8), named: Self.fileName(platform: platform, key: key), in: directory)
    }

    /// The lease that was removed, if a live one existed.
    @discardableResult
    public func remove(platform: DevicePlatform, key: String, now: Date = Date()) -> DeviceLease? {
        let name = Self.fileName(platform: platform, key: key)
        let existing = read(named: name, now: now)
        unlink((directory as NSString).appendingPathComponent(name))
        return existing
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
        guard let data = try? OffsiderPrivateDirectory.readOwnedFile(named: name, in: directory, maxBytes: Self.maxBytes),
              let lease = DeviceLease.parse(String(decoding: data, as: UTF8.self)) else { return nil }
        guard lease.expires > now else {
            unlink((directory as NSString).appendingPathComponent(name))
            return nil
        }
        return lease
    }
}

extension DeviceStateReport {
    static func leaseObject(_ lease: DeviceLease) -> OrderedJSON {
        .object([
            ("label", .string(lease.label)),
            ("since", .string(ProcessStamp.timestamp(lease.created))),
            ("expiresAt", .string(ProcessStamp.timestamp(lease.expires))),
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
