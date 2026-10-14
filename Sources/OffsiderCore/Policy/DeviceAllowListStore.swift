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

    public init(directory: UserConfigDirectory) {
        self.directory = directory
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
        return DeviceAllowListSnapshot(list: next, data: data)
    }

    private func read(in folder: String) throws -> DeviceAllowListSnapshot {
        guard let data = try OffsiderPrivateDirectory.readOwnedFile(named: Self.fileName, in: folder, maxBytes: Self.maximumBytes, uid: directory.uid) else {
            return .missing
        }
        return DeviceAllowListSnapshot(list: try DeviceAllowList.parse(data), data: data)
    }
}
