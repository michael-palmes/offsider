import Foundation
import OffsiderCore

/// Warns when an iOS simulator's screenshot repeats the last one while its tree changed.
@MainActor
enum FrozenDisplay {
    /// Off with the tree cache, and for any device that is not a simulator; a failed read or write only skips the warning.
    static func check(_ capture: CapturedScreen, tree: UITree, device: DeviceID, environment: TreeCacheEnvironment = .current) {
        guard environment.cacheOn, case .iosSimulator = DeviceIDClassifier.classify(device.rawValue), let directory = environment.directory(),
              let pixels = capture.untouchedPNG ?? capture.image.dataProvider?.data as Data? else { return }
        let name = FrozenDisplayRecord.fileName(device: device.rawValue)
        let current = FrozenDisplayRecord(image: FrozenDisplayRecord.digest(pixels: pixels), tree: FrozenDisplayRecord.digest(tree: tree))
        let previous = (try? OffsiderPrivateDirectory.readOwnedFile(named: name, in: directory, maxBytes: FrozenDisplayRecord.maximumBytes)).flatMap { $0 }.flatMap(FrozenDisplayRecord.init(data:))
        try? OffsiderPrivateDirectory.writeAtomically(current.encoded(), named: name, in: directory)
        guard current.looksFrozen(after: previous) else { return }
        let lock = "offsider button lock --device \(device.rawValue)"
        let home = "offsider button home --device \(device.rawValue)"
        Console.current.notice(.warning(
            "The display looks frozen: same picture, new elements",
            agent: "This screenshot matches the last one, though the elements on screen changed, so the simulator's display may be frozen. Run `\(lock)`, then `\(home)` twice.",
            try: lock
        ))
    }
}
