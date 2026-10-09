import Foundation

/// Whether `record-video` or `stream-video` may run: tree masks cannot be proven on every frame, so video refuses them.
public enum VideoMaskPolicy {
    public enum Decision: Equatable, Sendable {
        /// Record; `warning` goes to stderr.
        case record(warning: String?)
        /// `video_unmasked`: masks are in force that video cannot apply.
        case refuse(String)
        /// Exit 64: the flags contradict each other.
        case usage(String)
    }

    /// `treeFlags` are the tree-mask options given, such as `--mask-secure`; `run` is the active run's masks; `environmentSecure` is `OFFSIDER_MASK_SECURE=1`.
    public static func decide(command: String, treeFlags: [String], run: RunMasks?, environmentSecure: Bool, unmasked: Bool) -> Decision {
        let flags = list(treeFlags)
        if !treeFlags.isEmpty {
            if unmasked {
                return .usage("--unmasked records without the masks \(flags) \(treeFlags.count == 1 ? "asks" : "ask") for; drop one or the other.")
            }
            return .refuse(
                "\(command) cannot apply \(flags): video cannot be masked reliably frame by frame. "
                    + "For masked evidence use `screenshot` with the same flags, or screenshot steps in a batch; "
                    + "to record anyway, drop \(treeFlags.count == 1 ? "it" : "them") and pass --unmasked."
            )
        }
        var ambient: [String] = []
        if let run, !run.isEmpty {
            ambient.append("the evidence run masks \(run.summary)")
        }
        if environmentSecure {
            ambient.append("OFFSIDER_MASK_SECURE=1 is set")
        }
        let reasons = list(ambient)
        if unmasked {
            let because = ambient.isEmpty ? "" : " (\(reasons))"
            return .record(warning: "--unmasked: nothing in this video is masked by the accessibility tree\(because).")
        }
        guard !ambient.isEmpty else { return .record(warning: nil) }
        return .refuse(
            "\(command) will not run while \(reasons): video cannot be masked reliably frame by frame. "
                + "For masked evidence use `screenshot`, which applies those masks, or screenshot steps in a batch; pass --unmasked to record anyway."
        )
    }

    /// `a`, `a and b`, `a, b and c`.
    static func list(_ items: [String]) -> String {
        guard let last = items.last else { return "" }
        return items.count == 1 ? last : items.dropLast().joined(separator: ", ") + " and " + last
    }
}

/// Admits a `--mask-region` frame only when the screen had the first frame's orientation before and after its capture, and the frame has its size.
public struct VideoFrameGate: Equatable, Sendable {
    public let orientation: DeviceOrientation
    public let width: Int
    public let height: Int
    /// The read after the previous capture, which is this capture's read before.
    private var previous: DeviceOrientation?

    public init(orientation: DeviceOrientation, width: Int, height: Int) {
        self.orientation = orientation
        self.width = width
        self.height = height
        self.previous = orientation
    }

    /// `after` is the orientation read after this frame's capture; nil when it could not be read, which never proves a frame.
    public mutating func admits(width: Int, height: Int, after: DeviceOrientation?) -> Bool {
        defer { previous = after }
        return previous == orientation && after == orientation && width == self.width && height == self.height
    }
}

/// What `record-video --json` prints when the recording ends.
public struct VideoRecordingReport: Equatable, Sendable {
    public var path: String
    public var frames: Int
    public var heldFrames: Int
    /// Rectangles painted on every frame; zero without `--mask-region`.
    public var regions: Int
    public var unmasked: Bool

    public init(path: String, frames: Int, heldFrames: Int, regions: Int, unmasked: Bool) {
        self.path = path
        self.frames = frames
        self.heldFrames = heldFrames
        self.regions = regions
        self.unmasked = unmasked
    }

    public func jsonLine() -> String {
        let maskedBy: [(String, OrderedJSON)] = regions > 0 ? [(MaskKind.region.rawValue, .integer(regions))] : []
        return OrderedJSON.object([
            ("version", .integer(1)),
            ("path", .string(path)),
            ("frames", .integer(frames)),
            ("heldFrames", .integer(heldFrames)),
            ("maskedBy", .object(maskedBy)),
            ("unmasked", .bool(unmasked)),
        ]).rendered(compact: true)
    }
}
