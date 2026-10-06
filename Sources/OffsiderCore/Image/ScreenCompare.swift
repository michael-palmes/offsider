import Foundation

public enum ScreenCompare {
    public enum Outcome: Equatable, Sendable {
        case changed
        case unchanged
    }

    /// Exact pixel counts beside the tile verdict; they never change it.
    public struct PixelCounts: Equatable, Sendable {
        public let changedPixels: Int
        public let comparedPixels: Int
        public let bounds: PixelRect?

        public init(changedPixels: Int, comparedPixels: Int, bounds: PixelRect?) {
            self.changedPixels = changedPixels
            self.comparedPixels = comparedPixels
            self.bounds = bounds
        }
    }

    public struct Result: Equatable, Sendable {
        public let changedTiles: Int
        public let comparedTiles: Int
        public let changedFraction: Double
        public let outcome: Outcome
        public var pixels: PixelCounts?

        public init(changedTiles: Int, comparedTiles: Int, changedFraction: Double, outcome: Outcome, pixels: PixelCounts? = nil) {
            self.changedTiles = changedTiles
            self.comparedTiles = comparedTiles
            self.changedFraction = changedFraction
            self.outcome = outcome
            self.pixels = pixels
        }

        /// "Changed: 37 of 512 tiles (7.2%), 1830 pixels" or "Unchanged: 0 of 512 tiles, 0 pixels".
        public var summary: String {
            let counts = "\(changedTiles) of \(comparedTiles) tiles"
            let pixelCount = pixels.map { ", \($0.changedPixels) \($0.changedPixels == 1 ? "pixel" : "pixels")" } ?? ""
            switch outcome {
            case .changed:
                return "Changed: \(counts) (\(percentage))\(pixelCount)"
            case .unchanged:
                return changedTiles == 0 ? "Unchanged: \(counts)\(pixelCount)" : "Unchanged: \(counts) (\(percentage))\(pixelCount), within the threshold"
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
    /// The copy in the evidence run's folder, when a run is active.
    public var runFile: String?
    public var width: Int
    public var height: Int
    public var pixelsPerPoint: Double?
    public var region: PointRegion?
    /// The screen's shape, `portrait` or `landscape`.
    public var orientation: String?
    public var rotation: Int?
    public var display: ScreenDisplay?
    public var posture: Posture?
    public var upright: Bool
    public var format: ImageFormat?
    public var comparison: ScreenCompare.Result?
    /// Rectangles painted per kind asked for; nil unless a mask was asked for.
    public var maskedBy: [MaskKind: Int]?
    /// Where `--diff-output` wrote the diff image.
    public var diffPath: String?
    /// The mask selectors that matched nothing, such as `--mask-id profile-email`.
    public var maskUnmatched: [String]

    public init(
        path: String?,
        width: Int,
        height: Int,
        pixelsPerPoint: Double?,
        region: PointRegion?,
        orientation: String?,
        rotation: Int? = nil,
        display: ScreenDisplay? = nil,
        posture: Posture? = nil,
        upright: Bool,
        format: ImageFormat?,
        comparison: ScreenCompare.Result? = nil,
        maskedBy: [MaskKind: Int]? = nil,
        maskUnmatched: [String] = [],
        diffPath: String? = nil
    ) {
        self.path = path
        self.width = width
        self.height = height
        self.pixelsPerPoint = pixelsPerPoint
        self.region = region
        self.orientation = orientation
        self.rotation = rotation
        self.display = display
        self.posture = posture
        self.upright = upright
        self.format = format
        self.comparison = comparison
        self.maskedBy = maskedBy
        self.maskUnmatched = maskUnmatched
        self.diffPath = diffPath
    }

    /// Every rectangle painted, by any mask; nil unless a mask was asked for.
    public var masked: Int? {
        maskedBy.map { $0.values.reduce(0, +) }
    }

    public func jsonLine() -> String {
        OrderedJSON.object(jsonMembers).rendered(compact: true)
    }

    var jsonMembers: [(String, OrderedJSON)] {
        var members: [(String, OrderedJSON)] = [
            ("path", .optional(path, OrderedJSON.string)),
        ]
        if let runFile {
            members.append(("runFile", .string(runFile)))
        }
        members += [
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
        ]
        if let maskedBy, let masked {
            members.append(("masked", .integer(masked)))
            let kinds = MaskKind.allCases.compactMap { kind in maskedBy[kind].map { (kind.rawValue, OrderedJSON.integer($0)) } }
            members.append(("maskedBy", .object(kinds)))
            if !maskUnmatched.isEmpty {
                members.append(("maskUnmatched", .array(maskUnmatched.map(OrderedJSON.string))))
            }
        }
        members += [
            ("orientation", .optional(orientation, OrderedJSON.string)),
            ("rotation", .optional(rotation, OrderedJSON.integer)),
            ("display", display.map(\.jsonValue) ?? .null),
            ("posture", .optional(posture?.rawValue, OrderedJSON.string)),
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
            if let pixels = comparison.pixels {
                members += [
                    ("changedPixels", .integer(pixels.changedPixels)),
                    ("comparedPixels", .integer(pixels.comparedPixels)),
                    ("changedBounds", .optional(pixels.bounds) { bounds in
                        .object([("x", .integer(bounds.x)), ("y", .integer(bounds.y)), ("width", .integer(bounds.width)), ("height", .integer(bounds.height))])
                    }),
                ]
            }
            if let diffPath {
                members.append(("diffPath", .string(diffPath)))
            }
        }
        return members
    }

    private static func rounded(_ value: Double) -> Double {
        (value * 100).rounded() / 100
    }
}
