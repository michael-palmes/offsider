import Foundation

/// Overlays whose touch area reaches beyond the frame the accessibility tree reports.
public enum KnownOverlays {
    /// A React Native LogBox banner: `!, <message>` for one log or `<n>, <message>` for several.
    public static func isLogBoxBanner(_ label: String?) -> Bool {
        guard let label else { return false }
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let separator = trimmed.range(of: ", ") else { return false }
        let prefix = trimmed[..<separator.lowerBound]
        let isCount = prefix == "!" || (!prefix.isEmpty && prefix.unicodeScalars.allSatisfy { ("0"..."9").contains($0) })
        return isCount && separator.upperBound < trimmed.endIndex
    }

    /// The area a LogBox banner swallows: from its top edge to the bottom of the viewport, across the full width.
    public static func logBoxTouchArea(of frame: UIFrame, in viewport: UIFrame) -> UIFrame {
        let bottom = max(viewport.y + viewport.height, frame.y + frame.height)
        return UIFrame(x: viewport.x, y: frame.y, width: viewport.width, height: bottom - frame.y)
    }

    /// The logs a LogBox banner counts: 1 for `!, …`, n for `n, …`.
    public static func logBoxCount(_ label: String?) -> Int? {
        guard isLogBoxBanner(label), let label else { return nil }
        let prefix = label.trimmingCharacters(in: .whitespacesAndNewlines).prefix { $0 != "," }
        return prefix == "!" ? 1 : Int(prefix)
    }

    /// The on-screen LogBox banners' logs, or nil when none shows.
    public static func logBox(in tree: UITree) -> UITreeContext.LogBox? {
        let viewport = tree.viewport
        let counts = tree.roots.flatMap { $0.flattened() }.compactMap { node -> Int? in
            if let viewport, let frame = node.frame, !frame.isVisible(in: viewport) { return nil }
            return logBoxCount(node.label)
        }
        guard !counts.isEmpty else { return nil }
        return UITreeContext.LogBox(logs: counts.reduce(0, +), inspector: false)
    }
}
