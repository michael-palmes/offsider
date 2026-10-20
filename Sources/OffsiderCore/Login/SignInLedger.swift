import CryptoKit
import Darwin
import Foundation

/// Who Offsider last signed in on one device for one app. It names the saved login's key, never a username or password.
public struct SignInRecord: Equatable, Sendable {
    public static let version = 1
    public static let maximumBytes = 4096

    /// The app that owns the saved logins; a joined bundle id records the app it joined.
    public var app: String
    /// The bundle id in front when Offsider signed in.
    public var foreground: String
    /// The saved login's raw key: `*` for the untagged default.
    public var key: String
    public var platform: DevicePlatform
    /// The device's stable key: an AVD name, a phone serial or an uppercased UDID.
    public var device: String
    public var since: Date
    /// The device's boot marker when Offsider signed in, so a restart since then shows.
    public var bootMarker: String?

    public init(app: String, foreground: String, key: String, platform: DevicePlatform, device: String, since: Date, bootMarker: String?) {
        self.app = app
        self.foreground = foreground
        self.key = key
        self.platform = platform
        self.device = device
        self.since = since
        self.bootMarker = bootMarker
    }

    /// `{"v":1,"app":…,"foreground":…,"key":…,"platform":…,"device":…,"since":…,"bootMarker":…}`, with no `bootMarker` when unknown.
    public func encoded() -> Data {
        var members: [(String, OrderedJSON)] = [
            ("v", .integer(Self.version)),
            ("app", .string(app)),
            ("foreground", .string(foreground)),
            ("key", .string(key)),
            ("platform", .string(platform.rawValue)),
            ("device", .string(device)),
            ("since", .string(ProcessStamp.timestamp(since))),
        ]
        if let bootMarker { members.append(("bootMarker", .string(bootMarker))) }
        return Data(OrderedJSON.object(members).rendered(compact: true).utf8)
    }

    /// Nil for another version, a missing field or an unknown platform; unknown keys are ignored.
    public init?(data: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (object["v"] as? NSNumber)?.intValue == Self.version,
              let app = object["app"] as? String, !app.isEmpty,
              let foreground = object["foreground"] as? String,
              let key = object["key"] as? String, !key.isEmpty,
              let platform = (object["platform"] as? String).flatMap(DevicePlatform.init(rawValue:)),
              let device = object["device"] as? String, !device.isEmpty,
              let since = (object["since"] as? String).flatMap(ProcessStamp.date(fromTimestamp:)) else {
            return nil
        }
        self.init(app: app, foreground: foreground, key: key, platform: platform, device: device, since: since, bootMarker: object["bootMarker"] as? String)
    }
}

/// The last sign-in per device and app under the private directory's `signins/`: one 0600 file each, changed under one `flock`. Only `record(_:)` creates the directory.
public struct SignInLedger: Sendable {
    static let suffix = ".json"
    static let lockName = ".lock"

    let root: String

    public init(root: String = OffsiderPrivateDirectory.root) {
        self.root = root
    }

    /// `<first 16 hex of SHA-256 of "platform:device:app">.json`, so no id reaches a file name.
    public static func fileName(platform: DevicePlatform, device: String, app: String) -> String {
        let digest = SHA256.hash(data: Data("\(platform.rawValue):\(device):\(app)".utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined() + suffix
    }

    /// Replaces the record for its device and app.
    public func record(_ record: SignInRecord) throws {
        let data = record.encoded()
        let name = Self.fileName(platform: record.platform, device: record.device, app: record.app)
        try locked(creating: true) { directory in
            guard data.count <= SignInRecord.maximumBytes else {
                throw PrivateDirectoryError(.system(operation: "write", code: EFBIG), path: (directory as NSString).appendingPathComponent(name))
            }
            try OffsiderPrivateDirectory.writeAtomically(data, named: name, in: directory)
        }
    }

    public func record(platform: DevicePlatform, device: String, app: String) -> SignInRecord? {
        guard let directory = try? existingDirectory() else { return nil }
        return read(named: Self.fileName(platform: platform, device: device, app: app), in: directory)
    }

    /// Removes the record for this device and app; returns it when there was one.
    @discardableResult
    public func clear(platform: DevicePlatform, device: String, app: String) -> SignInRecord? {
        let name = Self.fileName(platform: platform, device: device, app: app)
        let cleared = try? locked { directory -> SignInRecord? in
            let existing = read(named: name, in: directory)
            OffsiderPrivateDirectory.removeFile(named: name, in: directory)
            return existing
        }
        return cleared ?? nil
    }

    /// Removes one saved login's records on every device; returns those removed.
    @discardableResult
    public func clear(app: String, key: String) -> [SignInRecord] {
        let removed = try? locked { directory in
            records(in: directory).filter { $0.record.app == app && $0.record.key == key }.map { entry in
                OffsiderPrivateDirectory.removeFile(named: entry.name, in: directory)
                return entry.record
            }
        }
        return removed ?? []
    }

    /// Removes every record made through `foreground` for `app`'s logins, as when that id stops sharing them.
    @discardableResult
    public func clear(app: String, foreground: String) -> [SignInRecord] {
        let removed = try? locked { directory in
            records(in: directory).filter { $0.record.app == app && $0.record.foreground == foreground }.map { entry in
                OffsiderPrivateDirectory.removeFile(named: entry.name, in: directory)
                return entry.record
            }
        }
        return removed ?? []
    }

    /// The app's sign-ins grouped by raw key, newest first; `bootMarker` gives a device's current marker, or nil when unknown.
    public func signIns(app: String, bootMarker: (DevicePlatform, String) -> String?) -> [String: [LoginSignIn]] {
        guard let directory = try? existingDirectory() else { return [:] }
        var grouped: [String: [LoginSignIn]] = [:]
        for record in records(in: directory).map(\.record) where record.app == app {
            let restarted = Self.restarted(recorded: record.bootMarker, current: bootMarker(record.platform, record.device))
            grouped[record.key, default: []].append(LoginSignIn(device: record.device, platform: record.platform, since: record.since, restarted: restarted))
        }
        return grouped.mapValues { signIns in
            signIns.sorted { $0.since != $1.since ? $0.since > $1.since : ($0.platform.rawValue, $0.device) < ($1.platform.rawValue, $1.device) }
        }
    }

    /// Nil unless both markers are known; true when they differ.
    public static func restarted(recorded: String?, current: String?) -> Bool? {
        guard let recorded, let current else { return nil }
        return recorded != current
    }

    /// Nil when nothing was ever recorded, so a read creates nothing.
    private func existingDirectory() throws -> String? {
        try OffsiderPrivateDirectory.existingSubdirectory(OffsiderPrivateDirectory.signInsDirectoryName, root: root)
    }

    /// Every readable record stored under its own file name; symlinks, foreign, oversized and misnamed files are skipped.
    private func records(in directory: String) -> [(name: String, record: SignInRecord)] {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []).filter { $0.hasSuffix(Self.suffix) && !$0.hasPrefix(".") }.sorted()
        return names.compactMap { name in read(named: name, in: directory).map { (name, $0) } }
    }

    private func read(named name: String, in directory: String) -> SignInRecord? {
        guard let data = try? OffsiderPrivateDirectory.readOwnedFile(named: name, in: directory, maxBytes: SignInRecord.maximumBytes),
              let record = SignInRecord(data: data),
              Self.fileName(platform: record.platform, device: record.device, app: record.app) == name else {
            return nil
        }
        return record
    }

    /// Holds the ledger's `flock` for `body`, which the kernel drops if the process dies; nil, running nothing, when nothing was recorded and `creating` is false.
    @discardableResult
    private func locked<T>(creating: Bool = false, _ body: (String) throws -> T) throws -> T? {
        let name = OffsiderPrivateDirectory.signInsDirectoryName
        guard let directory = try creating ? OffsiderPrivateDirectory.ensureSubdirectory(name, root: root) : existingDirectory() else { return nil }
        let lockPath = (directory as NSString).appendingPathComponent(Self.lockName)
        let descriptor = try OffsiderPrivateDirectory.openPrivateFile(lockPath)
        defer { Darwin.close(descriptor) }
        while flock(descriptor, LOCK_EX) != 0 {
            guard errno == EINTR else { throw PrivateDirectoryError(.system(operation: "flock", code: errno), path: lockPath) }
        }
        defer { flock(descriptor, LOCK_UN) }
        return try body(directory)
    }
}
