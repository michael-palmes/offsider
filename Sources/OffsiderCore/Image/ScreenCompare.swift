import Foundation

public enum ScreenCompare {
    public enum Outcome: Equatable, Sendable {
        case changed
        case unchanged
    }

    public struct Result: Equatable, Sendable {
        public let changedTiles: Int
        public let comparedTiles: Int
        public let changedFraction: Double
        public let outcome: Outcome

        public init(changedTiles: Int, comparedTiles: Int, changedFraction: Double, outcome: Outcome) {
            self.changedTiles = changedTiles
            self.comparedTiles = comparedTiles
            self.changedFraction = changedFraction
            self.outcome = outcome
        }

        /// "Changed: 37 of 512 tiles (7.2%)" or "Unchanged: 0 of 512 tiles".
        public var summary: String {
            let counts = "\(changedTiles) of \(comparedTiles) tiles"
            switch outcome {
            case .changed:
                return "Changed: \(counts) (\(percentage))"
            case .unchanged:
                return changedTiles == 0 ? "Unchanged: \(counts)" : "Unchanged: \(counts) (\(percentage)), within the threshold"
            }
        }

        private var percentage: String {
            String(format: "%.1f%%", changedFraction * 100)
        }
    }

    /// Changed only when strictly more than `threshold` of the compared tiles differ.
    public static func outcome(changedFraction: Double, threshold: Double) -> Outcome {
        changedFraction > threshold ? .changed : .unchanged
    }

    /// Nil when the fingerprints cover different sizes or grids.
    public static func compare(_ baseline: ImageFingerprint, _ current: ImageFingerprint, threshold: Double) -> Result? {
        guard let changed = baseline.changedTiles(comparedTo: current),
              let fraction = baseline.changedFraction(comparedTo: current) else {
            return nil
        }
        return Result(
            changedTiles: changed.count,
            comparedTiles: min(baseline.comparedTileCount, current.comparedTileCount),
            changedFraction: fraction,
            outcome: outcome(changedFraction: fraction, threshold: threshold)
        )
    }
}

/// What `screenshot --json` prints: one object, `pixelsPerPoint` after scaling.
public struct ScreenshotReport: Equatable, Sendable {
    public var path: String?
    public var width: Int
    public var height: Int
    public var pixelsPerPoint: Double?
    public var region: PointRegion?
    public var orientation: String?
    public var upright: Bool
    public var format: ImageFormat?
    public var comparison: ScreenCompare.Result?

    public init(
        path: String?,
        width: Int,
        height: Int,
        pixelsPerPoint: Double?,
        region: PointRegion?,
        orientation: String?,
        upright: Bool,
        format: ImageFormat?,
        comparison: ScreenCompare.Result? = nil
    ) {
        self.path = path
        self.width = width
        self.height = height
        self.pixelsPerPoint = pixelsPerPoint
        self.region = region
        self.orientation = orientation
        self.upright = upright
        self.format = format
        self.comparison = comparison
    }

    public func jsonLine() -> String {
        OrderedJSON.object(jsonMembers).rendered(compact: true)
    }

    var jsonMembers: [(String, OrderedJSON)] {
        var members: [(String, OrderedJSON)] = [
            ("path", .optional(path, OrderedJSON.string)),
            ("width", .integer(width)),
            ("height", .integer(height)),
            ("pixelsPerPoint", .optional(pixelsPerPoint.map(Self.rounded), OrderedJSON.number)),
            ("region", .optional(region) { region in
                .object([
                    ("x", .number(Self.rounded(region.x))),
                    ("y", .number(Self.rounded(region.y))),
                    ("width", .number(Self.rounded(region.width))),
                    ("height", .number(Self.rounded(region.height))),
                ])
            }),
            ("orientation", .optional(orientation, OrderedJSON.string)),
            ("upright", .bool(upright)),
            ("format", .optional(format?.name, OrderedJSON.string)),
        ]
        if let comparison {
            members += [
                ("changed", .bool(comparison.outcome == .changed)),
                ("changedTiles", .integer(comparison.changedTiles)),
                ("comparedTiles", .integer(comparison.comparedTiles)),
                ("changedFraction", .number((comparison.changedFraction * 10_000).rounded() / 10_000)),
            ]
        }
        return members
    }

    private static func rounded(_ value: Double) -> Double {
        (value * 100).rounded() / 100
    }
}
