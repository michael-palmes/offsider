import Darwin
import Foundation
import OffsiderCore
@testable import Offsider

/// A private temp `trees/` directory and a scripted wall clock, bound for one test.
@MainActor
final class TreeCacheFixture {
    let directory: String
    var now = Date(timeIntervalSince1970: 1_800_000_000)
    private(set) var sleeps: [Duration] = []

    init() throws {
        let root = (NSTemporaryDirectory() as NSString).appendingPathComponent("offsider-cache-test-\(UUID().uuidString)")
        directory = try OffsiderPrivateDirectory.ensureSubdirectory("trees", root: root)
    }

    deinit {
        try? FileManager.default.removeItem(atPath: (directory as NSString).deletingLastPathComponent)
    }

    var environment: TreeCacheEnvironment {
        let directory = directory
        return TreeCacheEnvironment(
            directory: { directory },
            now: { self.now },
            sleep: { duration in
                self.sleeps.append(duration)
                self.now += TransitionGuard.seconds(duration)
            }
        )
    }

    /// Runs `body` with this cache and a fresh ledger on the same clock.
    func run<T>(_ body: () async throws -> T) async throws -> T {
        let ledger = DeviceActivityLedger(now: { self.now })
        return try await DeviceActivityLedger.$current.withValue(ledger) {
            try await TreeCacheEnvironment.$current.withValue(environment) {
                try await body()
            }
        }
    }

    func path(for device: DeviceID) -> String {
        (directory as NSString).appendingPathComponent(TreeCacheRecord.fileName(platform: device.platform, device: device.rawValue))
    }

    func write(_ record: TreeCacheRecord) throws {
        let name = TreeCacheRecord.fileName(platform: record.platform, device: record.device)
        try OffsiderPrivateDirectory.writeAtomically(record.encoded(), named: name, in: directory)
    }

    func record(for device: DeviceID) throws -> TreeCacheRecord? {
        guard let data = FileManager.default.contents(atPath: path(for: device)) else { return nil }
        return try TreeCacheRecord(data: data)
    }

    /// A record of `tree` written `age` seconds ago, with the last input `inputAge` seconds ago (nil for none).
    func settledRecord(_ tree: UITree, age: TimeInterval = 5, inputAge: TimeInterval? = 5, marker: String? = nil) -> TreeCacheRecord {
        TreeCacheRecord(
            platform: tree.platform, device: tree.device, command: "describe-ui",
            writtenAt: now - age, treeReadAt: now - age, lastInputAt: inputAge.map { now - $0 },
            treeRole: .read, bootMarker: marker, appFrame: tree.applicationFrame, hash: TreeDiff.hash(tree), roots: tree.roots
        )
    }
}
