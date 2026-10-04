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
    /// The device's usable record, or nil; an expired or foreign-boot record is deleted.
    static func load(for device: DeviceID, backend: any DeviceBackend, environment: TreeCacheEnvironment = .current) async -> TreeCacheRecord? {
        guard let directory = environment.directory() else { return nil }
        return await Timings.measure("tree-cache") {
            let marker = await (backend as? any BootMarking)?.bootMarker(for: device)
            return read(device, in: directory, bootMarker: marker, now: environment.now())
        }
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
        for activity in activities {
            let device = activity.device
            let marking = backends.first { $0.platform == device.platform } as? any BootMarking
            await Timings.measure("tree-cache") {
                let marker = await marking?.bootMarker(for: device)
                let now = environment.now()
                let previous = read(device, in: directory, bootMarker: marker, now: now)
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
            }
        }
    }
}
