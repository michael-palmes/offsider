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

/// A full-screen modal an iOS app draws over its screen, whose screen beneath no read lists.
public struct ModalScreen: Equatable, Sendable {
    /// The backdrop below the status bar in portrait, which a text read covers.
    public var region: UIFrame
    /// Listed content starts a band below the backdrop's top, so the screen behind shows even where no mask names text.
    public var hidesBand: Bool
    /// Told only by an earlier read whose screen is gone, as moving to another screen looks too; the capture's text read settles it.
    public var byMemory: Bool

    public init(region: UIFrame, hidesBand: Bool, byMemory: Bool = false) {
        self.region = region
        self.hidesBand = hidesBand
        self.byMemory = byMemory
    }
}

/// A screen an iOS app hides from accessibility behind a sheet stays drawn, dimmed, while no read lists anything on it.
public enum HiddenScreen {
    /// Of the viewport's height: listed content that starts this far below a backdrop's top leaves a band no read accounts for.
    static let emptyBandShare = 0.25

    /// Where a backdrop covers the screen with nothing listed across its top band, below `statusBar` points in portrait; nil on Android, whose mask read lists hidden views.
    public static func region(in tree: UITree, belowStatusBar statusBar: Double) -> UIFrame? {
        modal(in: tree, belowStatusBar: statusBar).flatMap { $0.hidesBand ? $0.region : nil }
    }

    /// A screen-sized backdrop with content over it and none beneath: the band shape, a tappable one, or a whole-screen one over which `remembered` listed a screen now gone; nil on Android.
    public static func modal(in tree: UITree, belowStatusBar statusBar: Double, remembered: UITree? = nil) -> ModalScreen? {
        guard let found = scan(tree, belowStatusBar: statusBar) else { return nil }
        if let band = found.band { return ModalScreen(region: band, hidesBand: true) }
        if let tappable = found.candidates.first(where: \.tappable) { return ModalScreen(region: tappable.region, hidesBand: false) }
        guard let remembered, let viewport = tree.visibleRect else { return nil }
        let nodes = tree.roots.flatMap { $0.flattened() }
        // A modal's backdrop spans the whole screen; a content area below a listed header does not.
        for candidate in found.candidates where candidate.whole && vanished(from: remembered, under: candidate.region, current: nodes, viewport: viewport) {
            return ModalScreen(region: candidate.region, hidesBand: false, byMemory: true)
        }
        return nil
    }

    /// Whether `modal` could find one with a memory: a backdrop with listed content over it and none beneath, so the tree cache is worth reading.
    public static func mayHide(_ tree: UITree, belowStatusBar statusBar: Double) -> Bool {
        scan(tree, belowStatusBar: statusBar) != nil
    }

    /// The band shape's region, and every backdrop with listed content over it and none beneath; nil with neither.
    private static func scan(_ tree: UITree, belowStatusBar statusBar: Double) -> (band: UIFrame?, candidates: [(region: UIFrame, tappable: Bool, whole: Bool)])? {
        guard tree.platform == .ios, let viewport = tree.visibleRect, viewport.width > 0, viewport.height > statusBar,
              let app = tree.roots.first(where: { $0.role == .application }) else { return nil }
        var backdrops: [UIFrame] = []
        collectBackdrops(in: app, viewport: viewport, into: &backdrops)
        let nodes = app.flattened()
        let tappable = nodes.indices.filter { isTappableBackdrop(nodes[$0], viewport: viewport) }
        guard !backdrops.isEmpty || !tappable.isEmpty else { return nil }
        let inset = viewport.height > viewport.width ? statusBar : 0
        let screen = UIFrame(x: viewport.x, y: viewport.y + inset, width: viewport.width, height: viewport.height - inset)
        let content = nodes.indices.filter { nodes[$0].isContent(in: viewport) }
        for backdrop in backdrops {
            guard let shown = backdrop.intersection(screen),
                  let top = content.compactMap({ nodes[$0].frame?.intersection(shown)?.y }).min() else { continue }
            if top - shown.y >= emptyBandShare * viewport.height { return (band: shown, candidates: []) }
        }
        var candidates: [(region: UIFrame, tappable: Bool, whole: Bool)] = []
        for index in nodes.indices.filter({ isPlainBackdrop(nodes[$0], viewport: viewport) }) + tappable {
            guard let shown = nodes[index].frame?.intersection(viewport)?.intersection(screen) else { continue }
            let over = content.contains { $0 > index && nodes[$0].frame?.intersection(shown) != nil }
            let beneath = content.contains { $0 < index && nodes[$0].frame.map { shown.contains($0.center) } == true }
            if over, !beneath { candidates.append((region: shown, tappable: tappable.contains(index), whole: shown.encloses(screen, tolerance: 2))) }
        }
        guard !candidates.isEmpty else { return nil }
        return (band: nil, candidates: candidates)
    }

    /// At least half of what `remembered` listed in `region` is gone, neither listed again nor under something listed: a modal hides a whole screen, a live one loses one or two.
    static func vanished(from remembered: UITree, under region: UIFrame, current: [UINode], viewport: UIFrame) -> Bool {
        // A keyboard that went down takes its keys with it; that is no screen hidden.
        let before = withoutKeyboard(remembered.roots).filter { node in
            node.isContent(in: viewport) && node.frame.map { region.contains($0.center) } == true
        }
        let shown = current.filter { $0.isContent(in: viewport) }
        let gone = before.filter { old in
            guard let centre = old.frame?.center else { return false }
            return !shown.contains { now in
                now.frame?.encloses(UIFrame(x: centre.x, y: centre.y, width: 0, height: 0), tolerance: 2) == true
                    || (old.normalizedID != nil ? now.normalizedID == old.normalizedID : now.role == old.role && now.normalizedLabel == old.normalizedLabel)
            }
        }
        return !gone.isEmpty && gone.count * 2 >= before.count
    }

    /// A plain view the size of the screen with nothing labelled or tappable inside, wherever it sits in the tree.
    static func isPlainBackdrop(_ node: UINode, viewport: UIFrame) -> Bool {
        guard node.role == .group || node.role == .other, let frame = node.frame?.intersection(viewport),
              frame.width * frame.height >= viewport.width * viewport.height * TreeGapFill.backdropShare else { return false }
        return !node.children.contains { $0.contains { $0.normalizedLabel != nil || $0.isActionable } }
    }

    /// A button or tappable view the size of the screen with nothing tappable inside, such as a backdrop that closes the modal when tapped.
    static func isTappableBackdrop(_ node: UINode, viewport: UIFrame) -> Bool {
        guard node.role == .button || node.role == .link || ((node.role == .group || node.role == .other) && node.isActionable),
              let frame = node.frame?.intersection(viewport), frame.width * frame.height >= viewport.width * viewport.height * TreeGapFill.backdropShare else { return false }
        return !node.children.contains { $0.contains { $0.isActionable } }
    }

    static func withoutKeyboard(_ nodes: [UINode]) -> [UINode] {
        nodes.flatMap { $0.role == .keyboard ? [] : [$0] + withoutKeyboard($0.children) }
    }

    /// Whether a line no element lists now reads as text `remembered` listed and `current` does not: the old screen still drawn behind a modal.
    public static func showsRemembered(_ lines: [ScreenTextLine], remembered: UITree, current: UITree) -> Bool {
        func folded(_ text: String) -> String {
            String(text.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
        }
        let now = Set(current.roots.flatMap { $0.flattened() }.flatMap(\.searchableText).map(folded))
        let before = Set(remembered.roots.flatMap { $0.flattened() }.flatMap(\.searchableText).map(folded)).subtracting(now).filter { $0.count >= 4 }
        return lines.contains { line in
            let text = folded(line.text)
            return text.count >= 4 && before.contains { $0.contains(text) || text.contains($0) }
        }
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
