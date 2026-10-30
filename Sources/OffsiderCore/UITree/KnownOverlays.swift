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

    /// The area a LogBox banner swallows: from a point, plus `inset`, above its top edge to the bottom of the viewport, across the full width.
    public static func logBoxTouchArea(of frame: UIFrame, in viewport: UIFrame, inset: Double = 0) -> UIFrame {
        let top = frame.y - logBoxTouchMargin - inset
        let bottom = max(viewport.y + viewport.height, frame.y + frame.height)
        return UIFrame(x: viewport.x, y: top, width: viewport.width, height: bottom - top)
    }

    /// A LogBox toast's touch area, grown by `inset` (`logBoxTopInset`); nil for anything else.
    public static func logBoxTouchArea(of node: UINode, in viewport: UIFrame, inset: Double = 0) -> UIFrame? {
        guard let frame = node.frame, logBoxToast(node, viewport: viewport) != nil else { return nil }
        return logBoxTouchArea(of: frame, in: viewport, inset: inset)
    }

    /// How far above its frame a toast takes touches: its unlisted wrapper starts up to a point higher (0.67 on a 3x iOS simulator).
    static let logBoxTouchMargin = 1.0

    /// How much higher an edge-to-edge Android app's LogBox list takes touches: the status bar it pads by, shown by an app element drawn under a system bar; else 0.
    public static func logBoxTopInset(in tree: UITree) -> Double {
        guard tree.platform == .android, let windows = tree.windows,
              let app = (windows.first { $0.kind == "application" && $0.active } ?? windows.first { $0.kind == "application" })?.bounds,
              app.width > 0, app.height > 0 else { return 0 }
        let bars = windows.filter { $0.kind == "system" }.compactMap(\.bounds).filter { bar in
            bar.y <= app.y + 1 && bar.height > 0 && bar.height < app.height / 4 && bar.width >= 0.8 * app.width
        }
        guard let bottom = bars.map({ $0.y + $0.height }).max(), bottom > app.y + 1,
              let root = tree.roots.first(where: { $0.role == .application }) else { return 0 }
        let underBar = root.children.flatMap { $0.flattened() }.contains { node in
            guard let frame = node.frame, frame.width > 0, frame.height > 0 else { return false }
            return frame.y < bottom - 1 || frame.y + frame.height >= app.y + app.height - 1
        }
        return underBar ? bottom - app.y : 0
    }

    /// A screen-spanning modal with nothing labelled, named or actionable, as React Native's LogBox can leave on Android.
    static func isEmptyDialog(_ tree: UITree) -> Bool {
        let app = tree.roots.filter { $0.role != .keyboard }
        guard app.count == 1, let frame = app[0].frame, let screen = screenFrame(of: tree), CoverJudge.spans(frame, screen) else { return false }
        return !app[0].flattened().contains { $0.normalizedLabel != nil || $0.normalizedID != nil || $0.isActionable }
    }

    /// The screen in points, else every window together, as a dialog's own root is all the viewport knows.
    private static func screenFrame(of tree: UITree) -> UIFrame? {
        if let screen = tree.screen, screen.width > 0, screen.height > 0 {
            return UIFrame(x: 0, y: 0, width: screen.width, height: screen.height)
        }
        let bounds = (tree.windows ?? []).compactMap(\.bounds).filter { $0.width > 0 && $0.height > 0 }
        return bounds.dropFirst().reduce(bounds.first) { $0?.union($1) }
    }

    /// The text a LogBox banner shows after its `!, ` or `n, ` prefix, with line breaks and runs of spaces as one space.
    public static func logBoxMessage(_ label: String?) -> String? {
        guard isLogBoxBanner(label), let label else { return nil }
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let separator = trimmed.range(of: ", ") else { return nil }
        return trimmed[separator.upperBound...].split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// The logs a LogBox banner counts: 1 for `!, …`, n for `n, …`.
    public static func logBoxCount(_ label: String?) -> Int? {
        guard isLogBoxBanner(label), let label else { return nil }
        let prefix = label.trimmingCharacters(in: .whitespacesAndNewlines).prefix { $0 != "," }
        return prefix == "!" ? 1 : Int(prefix)
    }

    /// LogBox's toast container sits 10 points in from each side, near the bottom; a toast is 48 points high
    /// on iOS and up to 64 on Android, where the frame takes in the container's padding.
    static let toastInset = 10.0
    static let toastInsetTolerance = 3.0
    /// The 10 pt inset grows to about 12.3 pt each side under the largest Display Zoom.
    static let toastWidthTolerance = 5.0
    static let toastHeights = 44.0...68.0
    /// Toasts and the inspector's buttons sit within this many points of the bottom.
    static let bottomBand = 160.0

    /// One LogBox toast by its frame, then its `!, ` or `n, ` label; nil for anything else, such as a full-width call to action.
    public static func logBoxToast(_ node: UINode, viewport: UIFrame) -> LogBoxToast? {
        guard let frame = node.frame,
              abs(frame.x - viewport.x - toastInset) <= toastInsetTolerance,
              abs(frame.width - (viewport.width - 2 * toastInset)) <= toastWidthTolerance,
              toastHeights.contains(frame.height),
              frame.y + frame.height >= viewport.y + viewport.height - bottomBand,
              let count = logBoxCount(node.label) else {
            return nil
        }
        return LogBoxToast(count: count, frame: frame, message: logBoxMessage(node.label) ?? "")
    }

    /// Every LogBox toast on screen, bottom first and numbered from 1, as `rn logbox dismiss` clears them.
    public static func logBoxToasts(in roots: [UINode], viewport: UIFrame?) -> [LogBoxToast] {
        guard let viewport else { return [] }
        return roots.flatMap { $0.flattened() }
            .compactMap { logBoxToast($0, viewport: viewport) }
            .sorted { $0.frame.y > $1.frame.y }
            .enumerated()
            .map { offset, toast in
                var numbered = toast
                numbered.index = offset + 1
                return numbered
            }
    }

    /// The toast whose message holds `text` (spacing and case aside), for a selector that missed because it was there.
    public static func logBoxToast(containing text: String, in roots: [UINode], viewport: UIFrame?) -> LogBoxToast? {
        let wanted = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard wanted.count >= 3 else { return nil }
        return logBoxToasts(in: roots, viewport: viewport).first { $0.message.localizedCaseInsensitiveContains(wanted) }
    }

    /// The full-screen LogBox inspector: a `Log n of m` header, or `Dismiss` and `Minimize` buttons near the bottom.
    public static func logBoxInspector(in roots: [UINode], viewport: UIFrame?) -> LogBoxInspector? {
        let nodes = roots.flatMap { $0.flattened() }
        let header = nodes.lazy.compactMap { node in node.label.flatMap(LogBoxInspector.position(in:)) }.first
        let band: Double? = viewport.map { $0.y + $0.height - bottomBand }
        func inBand(_ node: UINode) -> Bool {
            guard let band else { return true }
            guard let frame = node.frame else { return false }
            return frame.y + frame.height >= band
        }
        func button(_ label: String) -> UINode? {
            nodes.first { $0.label?.trimmingCharacters(in: .whitespacesAndNewlines) == label && inBand($0) }
        }
        let dismiss = button("Dismiss")
        let minimize = button("Minimize")
        guard header != nil || (dismiss != nil && minimize != nil) else { return nil }
        return LogBoxInspector(log: header?.log, of: header?.of, dismiss: dismiss?.frame, minimize: minimize?.frame)
    }

    /// The LogBox state a tree shows, or nil when neither toasts nor the inspector are there.
    public static func logBox(in tree: UITree) -> UITreeContext.LogBox? {
        if let inspector = logBoxInspector(in: tree.roots, viewport: tree.viewport) {
            return UITreeContext.LogBox(logs: inspector.of ?? 0, inspector: true)
        }
        let toasts = logBoxToasts(in: tree.roots, viewport: tree.viewport)
        guard !toasts.isEmpty else { return nil }
        return UITreeContext.LogBox(logs: toasts.reduce(0) { $0 + $1.count }, inspector: false)
    }
}

/// One LogBox toast: its log count, frame, message, place from the bottom (1 is the lowest), and the points to tap.
public struct LogBoxToast: Equatable, Sendable {
    public var count: Int
    public var frame: UIFrame
    /// The banner's text after its count, unredacted.
    public var message: String
    public var index: Int

    public init(count: Int, frame: UIFrame, message: String = "", index: Int = 1) {
        self.count = count
        self.frame = frame
        self.message = message
        self.index = index
    }

    /// LogBox's clear button sits 22 points in from the toast's right-hand edge.
    public var dismissPoint: UIPoint {
        UIPoint(x: frame.x + frame.width - 22, y: frame.y + frame.height / 2)
    }

    /// The body, 40 percent across, which opens the inspector.
    public var bodyPoint: UIPoint {
        UIPoint(x: frame.x + frame.width * 0.4, y: frame.y + frame.height / 2)
    }
}

/// The LogBox inspector: which log it shows, and its two bottom buttons when the tree has them.
public struct LogBoxInspector: Equatable, Sendable {
    public var log: Int?
    public var of: Int?
    public var dismiss: UIFrame?
    public var minimize: UIFrame?

    /// `Log 1 of 2` as (1, 2).
    static func position(in label: String) -> (log: Int, of: Int)? {
        let words = label.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ")
        guard words.count == 4, words[0] == "Log", words[2] == "of", let log = Int(words[1]), let of = Int(words[3]) else { return nil }
        return (log, of)
    }
}
