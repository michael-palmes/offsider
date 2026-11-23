import Darwin
import Foundation

/// The allow-list file as read: its parsed entries and the bytes they came from, for the seal.
public struct DeviceAllowListSnapshot: Equatable, Sendable {
    public let list: DeviceAllowList
    /// Empty when no file exists.
    public let data: Data

    public init(list: DeviceAllowList, data: Data) {
        self.list = list
        self.data = data
    }

    public static let missing = DeviceAllowListSnapshot(list: .empty, data: Data())
}

/// Reads and writes `allowed-devices.json` in `~/.config/offsider`: a private 0600 file, replaced atomically under a `flock`.
public struct DeviceAllowListStore: Sendable {
    public static let fileName = "allowed-devices.json"
    public static let lockName = ".allowed-devices.lock"
    public static let maximumBytes = 64 * 1024

    let directory: UserConfigDirectory
    /// Where each allowance written or taken away is recorded; nil in tests that only read and write the list.
    public let audit: AuditTrail?

    public init(directory: UserConfigDirectory, audit: AuditTrail? = nil) {
        self.directory = directory
        self.audit = audit
    }

    /// The file's path, for messages.
    public var path: String {
        ((directory.home as NSString).appendingPathComponent(UserConfigDirectory.configName) as NSString)
            .appendingPathComponent(UserConfigDirectory.offsiderName + "/" + Self.fileName)
    }

    /// The current list; a missing file or folder is an empty list. Throws when the file is unsafe or does not parse.
    public func load() throws -> DeviceAllowListSnapshot {
        guard let folder = try directory.existing() else { return .missing }
        return try read(in: folder)
    }

    /// Under the lock, passes the current file to `change` (an unreadable one as an empty list with its bytes) and writes the list it returns,
    /// then hands the new bytes to `commit` (the seal) before the lock is released. A throw from `change` writes nothing.
    @discardableResult
    public func update(
        _ change: (DeviceAllowListSnapshot) throws -> DeviceAllowList,
        commit: (Data) throws -> Void = { _ in }
    ) throws -> DeviceAllowListSnapshot {
        let folder = try directory.ensure()
        let lockPath = (folder as NSString).appendingPathComponent(Self.lockName)
        let descriptor = try OffsiderPrivateDirectory.openPrivateFile(lockPath, uid: directory.uid)
        defer { Darwin.close(descriptor) }
        while flock(descriptor, LOCK_EX) != 0 {
            guard errno == EINTR else { throw PrivateDirectoryError(.system(operation: "flock", code: errno), path: lockPath) }
        }
        defer { flock(descriptor, LOCK_UN) }
        let current: DeviceAllowListSnapshot
        do {
            current = try read(in: folder)
        } catch {
            let raw = (try? OffsiderPrivateDirectory.readOwnedFile(named: Self.fileName, in: folder, maxBytes: Self.maximumBytes, uid: directory.uid)) ?? nil
            current = DeviceAllowListSnapshot(list: .empty, data: raw ?? Data("unreadable".utf8))
        }
        let next = try change(current)
        let data = next.encoded()
        try OffsiderPrivateDirectory.writeAtomically(data, named: Self.fileName, in: folder, uid: directory.uid)
        try commit(data)
        if let audit {
            audit.record(Self.auditEvents(from: current.list, to: next, now: audit.now(), managed: audit.managed()))
        }
        return DeviceAllowListSnapshot(list: next, data: data)
    }

    /// `allowed` for each entry that is new or changed and `withdrawn` for each that left; one pruned after it expired says so.
    static func auditEvents(from old: DeviceAllowList, to new: DeviceAllowList, now: Date, managed: Bool) -> [AuditEvent] {
        let allowed = new.entries.filter { old.entry(platform: $0.platform, key: $0.key) != $0 }.map { entry in
            AuditEvent(
                .allowed, platform: entry.platform, key: entry.key, app: entry.pinnedApps.count == 1 ? entry.pinnedApps[0] : nil,
                testDevice: entry.testDevice, managed: managed, expires: entry.expires, pins: entry.pinnedApps.count
            )
        }
        let withdrawn = old.entries.filter { new.entry(platform: $0.platform, key: $0.key) == nil }.map { entry in
            AuditEvent(
                .withdrawn, platform: entry.platform, key: entry.key, refusal: entry.isActive(now: now) ? nil : DeviceRefusal.expired(now).code,
                testDevice: entry.testDevice, managed: managed, pins: entry.pinnedApps.count
            )
        }
        let newer = old.newer.filter { new.newerEntry(platform: $0.platform, key: $0.key) == nil && new.entry(platform: $0.platform, key: $0.key) == nil }.map {
            AuditEvent(.withdrawn, platform: $0.platform, key: $0.key, managed: managed)
        }
        return allowed + withdrawn + newer
    }

    private func read(in folder: String) throws -> DeviceAllowListSnapshot {
        guard let data = try OffsiderPrivateDirectory.readOwnedFile(named: Self.fileName, in: folder, maxBytes: Self.maximumBytes, uid: directory.uid) else {
            return .missing
        }
        return DeviceAllowListSnapshot(list: try DeviceAllowList.parse(data), data: data)
    }
}
