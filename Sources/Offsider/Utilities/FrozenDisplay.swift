import Foundation
import OffsiderCore

/// Warns when an iOS simulator's screenshot repeats the last one while its tree changed.
@MainActor
enum FrozenDisplay {
    /// A frozen display still moves its status bar's clock and its bottom edge, so both are left out of the picture and the tree alike.
    static let bands = (top: IOSBackend.statusBarHeight, bottom: 34.0)

    /// Off with the tree cache, and for any device that is not a simulator; a failed read or write only skips the warning.
    static func check(_ capture: CapturedScreen, tree: UITree, device: DeviceID, environment: TreeCacheEnvironment = .current) {
        guard environment.cacheOn, case .iosSimulator = DeviceIDClassifier.classify(device.rawValue), let directory = environment.directory(),
              let pixels = capture.image.dataProvider?.data as Data? else { return }
        let name = FrozenDisplayRecord.fileName(device: device.rawValue)
        let current = FrozenDisplayRecord(image: digest(pixels, of: capture), tree: FrozenDisplayRecord.digest(tree: tree, leavingOut: bands))
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

    /// The rows between the bands; the whole picture when its scale is unknown.
    static func digest(_ pixels: Data, of capture: CapturedScreen) -> String {
        let image = capture.image
        guard let scale = capture.pixelsPerPoint, image.bytesPerRow > 0, pixels.count >= image.bytesPerRow * image.height else {
            return FrozenDisplayRecord.digest(pixels: pixels)
        }
        let first = min(image.height, Int((bands.top * scale).rounded()))
        let end = max(first, image.height - Int((bands.bottom * scale).rounded()))
        return FrozenDisplayRecord.digest(pixels: pixels.subdata(in: (pixels.startIndex + first * image.bytesPerRow)..<(pixels.startIndex + end * image.bytesPerRow)))
    }
}
