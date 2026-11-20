import Foundation

/// One line of text recognised in a capture, in points.
public struct ScreenTextLine: Equatable, Sendable {
    public var text: String
    public var frame: UIFrame

    public init(text: String, frame: UIFrame) {
        self.text = text
        self.frame = frame
    }
}

/// A screen an iOS app hides from accessibility behind a sheet stays drawn, dimmed, while no read lists anything on it.
public enum HiddenScreen {
    /// Of the viewport's height: listed content that starts this far below a backdrop's top leaves a band no read accounts for.
    static let emptyBandShare = 0.25

    /// Where a backdrop covers the screen with nothing listed across its top band, below `statusBar` points in portrait; nil on Android, whose mask read lists hidden views.
    public static func region(in tree: UITree, belowStatusBar statusBar: Double) -> UIFrame? {
        guard tree.platform == .ios, let viewport = tree.visibleRect, viewport.width > 0, viewport.height > statusBar,
              let app = tree.roots.first(where: { $0.role == .application }) else { return nil }
        var backdrops: [UIFrame] = []
        collectBackdrops(in: app, viewport: viewport, into: &backdrops)
        guard !backdrops.isEmpty else { return nil }
        let inset = viewport.height > viewport.width ? statusBar : 0
        let screen = UIFrame(x: viewport.x, y: viewport.y + inset, width: viewport.width, height: viewport.height - inset)
        let content = app.flattened().compactMap { $0.isContent(in: viewport) ? $0.frame : nil }
        for backdrop in backdrops {
            guard let shown = backdrop.intersection(screen),
                  let top = content.compactMap({ $0.intersection(shown)?.y }).min() else { continue }
            if top - shown.y >= emptyBandShare * viewport.height { return shown }
        }
        return nil
    }

    /// The lines no listed element accounts for, with at least two letters or digits; the keyboard counts as listed.
    public static func unlisted(_ lines: [ScreenTextLine], in tree: UITree) -> [ScreenTextLine] {
        guard let viewport = tree.visibleRect else { return [] }
        let listed = tree.roots.flatMap { root in
            root.role == .keyboard ? [root] : root.flattened().filter { $0.isContent(in: viewport) && ($0.normalizedLabel != nil || $0.value?.isEmpty == false) }
        }.compactMap(\.frame)
        return lines.filter { line in
            line.text.unicodeScalars.count(where: CharacterSet.alphanumerics.contains) >= 2
                && !listed.contains { $0.encloses(UIFrame(x: line.frame.center.x, y: line.frame.center.y, width: 0, height: 0), tolerance: 2) }
        }
    }

    /// The frames of `lines` that `plan`'s emails and text patterns match, painted whole, and the patterns that matched one.
    public static func targets(_ lines: [ScreenTextLine], plan: MaskPlan) throws -> (frames: [MaskKind: [UIFrame]], matched: Set<String>) {
        var frames: [MaskKind: [UIFrame]] = [:]
        var matched: Set<String> = []
        func matching(_ pattern: String) throws -> [UIFrame] {
            let regex = try MaskPlan.compile(pattern)
            return lines.filter { regex.firstMatch(in: $0.text, range: NSRange($0.text.startIndex..., in: $0.text)) != nil }.map(\.frame)
        }
        for pattern in plan.texts {
            let found = try matching(pattern)
            if !found.isEmpty { matched.insert(pattern) }
            frames[.text, default: []] += found
        }
        if plan.emails {
            frames[.emails] = try matching(PersonalData.emailPattern)
        }
        return (frames.filter { !$0.value.isEmpty }, matched)
    }

    /// Screen-sized plain views with nothing labelled inside, such as a sheet's dimmed backdrop; a map, image or list is content of its own.
    static func collectBackdrops(in node: UINode, viewport: UIFrame, into frames: inout [UIFrame]) {
        guard let frame = node.frame?.intersection(viewport), frame.width * frame.height >= viewport.width * viewport.height * TreeGapFill.backdropShare else { return }
        if node.role == .group || node.role == .other, !node.children.contains(where: { $0.contains { $0.normalizedLabel != nil || $0.isActionable } }) {
            frames.append(frame)
            return
        }
        for child in node.children { collectBackdrops(in: child, viewport: viewport, into: &frames) }
    }
}
