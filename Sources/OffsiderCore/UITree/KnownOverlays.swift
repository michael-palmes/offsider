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
}
