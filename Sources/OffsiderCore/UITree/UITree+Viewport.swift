import Foundation

extension UITree {
    /// The union of the `.application` and `.keyboard` root frames with a positive size; nil when there is none.
    public static func viewport(in roots: [UINode]) -> UIFrame? {
        let frames = roots
            .filter { $0.role == .application || $0.role == .keyboard }
            .compactMap(\.frame)
            .filter { $0.width > 0 && $0.height > 0 }
        guard let first = frames.first else {
            return nil
        }
        return frames.dropFirst().reduce(first) { $0.union($1) }
    }

    public var viewport: UIFrame? {
        Self.viewport(in: roots)
    }
}

extension UIFrame {
    public var center: UIPoint {
        UIPoint(x: x + width / 2, y: y + height / 2)
    }

    /// Half-open on both axes, the rule `UITree.deepestNode(at:)` uses.
    public func contains(_ point: UIPoint) -> Bool {
        point.x >= x && point.x < x + width && point.y >= y && point.y < y + height
    }

    /// True when the frame overlaps `viewport` by at least 1 pt on both axes.
    public func isVisible(in viewport: UIFrame) -> Bool {
        let overlapWidth = min(x + width, viewport.x + viewport.width) - max(x, viewport.x)
        let overlapHeight = min(y + height, viewport.y + viewport.height) - max(y, viewport.y)
        return overlapWidth >= 1 && overlapHeight >= 1
    }

    /// The overlap with `other`, or nil when they do not overlap.
    public func intersection(_ other: UIFrame) -> UIFrame? {
        let minX = max(x, other.x)
        let minY = max(y, other.y)
        let maxX = min(x + width, other.x + other.width)
        let maxY = min(y + height, other.y + other.height)
        guard maxX > minX, maxY > minY else { return nil }
        return UIFrame(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// `(20, 10700) 350x44`: whole numbers without a fraction, others to 1 decimal.
    public var summary: String {
        "(\(Self.format(x)), \(Self.format(y))) \(sizeSummary)"
    }

    /// `393x852`, formatted as in `summary`.
    public var sizeSummary: String {
        "\(Self.format(width))x\(Self.format(height))"
    }

    func union(_ other: UIFrame) -> UIFrame {
        let minX = min(x, other.x)
        let minY = min(y, other.y)
        let maxX = max(x + width, other.x + other.width)
        let maxY = max(y + height, other.y + other.height)
        return UIFrame(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private static func format(_ value: Double) -> String {
        if value.rounded() == value, abs(value) < 1e15 {
            return String(Int(value))
        }
        return String(format: "%.1f", value)
    }
}
