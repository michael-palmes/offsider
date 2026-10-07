import Foundation
import OffsiderCore

/// Device ids no real device uses, for commands that lock in the shared private directory, and cleanup of what they leave.
enum TestDevices {
    /// Seconds a re-acquire after a release may wait: a child another test spawns keeps a copy of the descriptor until its exec completes, while a lock never freed still refuses.
    static let releaseGrace: Double = 10

    static func simulatorUDID() -> String { UUID().uuidString }

    /// An `emulator-N` serial far above any running emulator's console port.
    static func emulatorSerial() -> String { "emulator-\(2 * Int.random(in: 10_000...14_999))" }

    /// Deletes the lock and tree cache files left for `id`; commands never delete them, but a test may clean its own.
    static func removePrivateFiles(platform: DevicePlatform, id: String, root: String = OffsiderPrivateDirectory.root) {
        let canonical = platform == .ios ? id.uppercased() : id
        let paths = [
            "\(OffsiderPrivateDirectory.locksDirectoryName)/\(DeviceLockKey(platform: platform, id: canonical).fileName)",
            "\(OffsiderPrivateDirectory.treesDirectoryName)/\(TreeCacheRecord.fileName(platform: platform, device: canonical))",
        ]
        for path in paths {
            try? FileManager.default.removeItem(atPath: (root as NSString).appendingPathComponent(path))
        }
    }
}
