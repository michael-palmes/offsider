import Darwin
import Foundation
import OffsiderCore

/// Where the tree cache lives and how its clock runs; a test binds its own directory and clock.
struct TreeCacheEnvironment: Sendable {
    static let environmentKey = "OFFSIDER_TREE_CACHE"

    /// The `trees/` directory, or nil when the cache is off or the directory cannot be made private.
    var directory: @Sendable () -> String?
    var now: @Sendable @MainActor () -> Date
    var sleep: @Sendable @MainActor (Duration) async throws -> Void

    @TaskLocal static var current = TreeCacheEnvironment.live

    static let live = TreeCacheEnvironment(
        directory: {
            guard isEnabled(ProcessInfo.processInfo.environment) else { return nil }
            return try? OffsiderPrivateDirectory.ensureSubdirectory(OffsiderPrivateDirectory.treesDirectoryName)
        },
        now: { Date() },
        sleep: { try await Task.sleep(for: $0) }
    )

    static func isEnabled(_ environment: [String: String]) -> Bool {
        environment[environmentKey]?.trimmingCharacters(in: .whitespaces).lowercased() != "off"
    }
}

/// Reads and writes the per-device tree cache: one 0600 file per device under the private directory's `trees/`.
@MainActor
enum TreeCache {
    /// The device's usable record, or nil; an expired or foreign-boot record is deleted, and so is every other device's expired file.
    static func load(for device: DeviceID, backend: any DeviceBackend, environment: TreeCacheEnvironment = .current) async -> TreeCacheRecord? {
        guard let directory = environment.directory() else { return nil }
        return await Timings.measure("tree-cache") {
            let marker = await (backend as? any BootMarking)?.bootMarker(for: device)
            let record = read(device, in: directory, bootMarker: marker, now: environment.now())
            sweepOnce(directory)
            return record
        }
    }

    /// The device's password fields from earlier reads in this boot, which a plain text field at the same id or frame reveals; nil with none or no cache.
    static func revealedSecrets(for device: DeviceID, backend: any DeviceBackend, environment: TreeCacheEnvironment = .current) async -> RevealedSecrets? {
        guard let directory = environment.directory() else { return nil }
        return await Timings.measure("tree-cache") {
            let marker = await (backend as? any BootMarking)?.bootMarker(for: device)
            let record = readSecure(device, in: directory, bootMarker: marker, now: environment.now())
            sweepOnce(directory)
            return record.map(RevealedSecrets.init)
        }
    }

    private static func readSecure(_ device: DeviceID, in directory: String, bootMarker: String?, now: Date) -> SecureFieldRecord? {
        let name = SecureFieldRecord.fileName(platform: device.platform, device: device.rawValue)
        guard let data = try? OffsiderPrivateDirectory.readOwnedFile(named: name, in: directory, maxBytes: SecureFieldRecord.maximumBytes) else {
            return nil
        }
        guard let record = try? SecureFieldRecord(data: data),
              record.platform == device.platform, record.device == device.rawValue,
              record.isUsable(now: now, bootMarker: bootMarker) else {
            OffsiderPrivateDirectory.removeFile(named: name, in: directory)
            return nil
        }
        return record
    }

    /// Directories this process has swept, so a command that reads the cache twice lists it once.
    private static var swept: Set<String> = []

    private static func sweepOnce(_ directory: String) {
        guard swept.insert(directory).inserted else { return }
        // File times are wall-clock times, whatever clock the cache runs on.
        sweep(directory, now: Date())
    }

    private static func read(_ device: DeviceID, in directory: String, bootMarker: String?, now: Date) -> TreeCacheRecord? {
        let name = TreeCacheRecord.fileName(platform: device.platform, device: device.rawValue)
        guard let data = try? OffsiderPrivateDirectory.readOwnedFile(named: name, in: directory, maxBytes: TreeCacheRecord.maximumBytes) else {
            return nil
        }
        guard let record = try? TreeCacheRecord(data: data),
              record.platform == device.platform, record.device == device.rawValue,
              record.isUsable(now: now, bootMarker: bootMarker) else {
            OffsiderPrivateDirectory.removeFile(named: name, in: directory)
            return nil
        }
        return record
    }

    /// Writes one record per device the command read or sent input to; never throws, since losing the cache costs one read.
    static func commit(
        command: String,
        effect: CommandEffect,
        claimed: Set<DeviceLockKey>,
        backends: [any DeviceBackend],
        sentNothing: Bool = false,
        ledger: DeviceActivityLedger? = nil,
        environment: TreeCacheEnvironment = .current
    ) async {
        guard effect != .none, let directory = environment.directory() else { return }
        var activities = (ledger ?? .current).activities
        if effect == .input {
            for key in claimed where !activities.contains(where: { $0.device.platform == key.platform && $0.device.rawValue == key.id }) {
                activities.append(DeviceActivityLedger.Activity(device: DeviceID(rawValue: key.id, platform: key.platform)))
            }
        }
        var written = Set<String>()
        for activity in activities {
            let device = activity.device
            let marking = backends.first { $0.platform == device.platform } as? any BootMarking
            await Timings.measure("tree-cache") {
                let marker = await marking?.bootMarker(for: device)
                let now = environment.now()
                let previous = read(device, in: directory, bootMarker: marker, now: now)
                var activity = activity
                if let tree = activity.tree {
                    activity.tree = maskedForCache(tree, device: device, directory: directory, bootMarker: marker, now: now, written: &written)
                }
                guard let record = TreeCacheRecord.committing(
                    activity, previous: previous, command: command,
                    inputAtEnd: effect == .input && !sentNothing, bootMarker: marker, now: now
                ) else { return }
                var data = record.encoded()
                if data.count > TreeCacheRecord.maximumBytes {
                    data = record.withoutTree().encoded()
                }
                let name = TreeCacheRecord.fileName(platform: device.platform, device: device.rawValue)
                try? OffsiderPrivateDirectory.writeAtomically(data, named: name, in: directory)
                written.insert(name)
            }
        }
        // File times are wall-clock times, whatever clock the cache runs on.
        sweep(directory, now: Date(), keeping: written)
    }

    /// The tree with the config's and run's masked values and revealed password fields hidden, and the device's password
    /// fields recorded beside it; nil, so no tree is cached, when `offsider.mask.json` cannot be used.
    private static func maskedForCache(
        _ tree: UITree, device: DeviceID, directory: String, bootMarker: String?, now: Date, written: inout Set<String>
    ) -> UITree? {
        let previous = readSecure(device, in: directory, bootMarker: bootMarker, now: now)
        guard let mask = try? AmbientMasks.treeMask(revealed: previous.map(RevealedSecrets.init)) else { return nil }
        let name = SecureFieldRecord.fileName(platform: device.platform, device: device.rawValue)
        if let next = SecureFieldRecord.next(previous: previous, tree: tree, bootMarker: bootMarker, now: now) {
            try? OffsiderPrivateDirectory.writeAtomically(next.encoded(), named: name, in: directory)
            written.insert(name)
        } else if previous != nil {
            OffsiderPrivateDirectory.removeFile(named: name, in: directory)
        }
        return tree.redacted(mask, scope: .cache)
    }

    /// Deletes every device's cache file last written a lifetime ago, so a device no command touches again keeps no tree on disk.
    static func sweep(_ directory: String, now: Date, keeping written: Set<String> = []) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory) else { return }
        for name in names where name.hasSuffix(".json") && !written.contains(name) {
            var info = stat()
            guard lstat((directory as NSString).appendingPathComponent(name), &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { continue }
            let modified = Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec) + TimeInterval(info.st_mtimespec.tv_nsec) / 1e9)
            if TreeCacheRecord.isExpired(modifiedAt: modified, now: now) {
                OffsiderPrivateDirectory.removeFile(named: name, in: directory)
            }
        }
    }
}
