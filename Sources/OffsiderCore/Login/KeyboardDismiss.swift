import Foundation

/// Points that resign the software keyboard without pressing a key or a control.
public enum KeyboardDismiss {
    /// How many points `login` tries before it gives up on the keyboard.
    public static let attempts = 3
    /// A tap this close to a form field can land in the field's own wrapper, which keeps focus.
    static let fieldMargin: Double = 16
    /// Two tries this close together would likely reach the same view.
    static let spacing: Double = 44

    /// The first point `points` offers when the form is unknown.
    public static func point(in tree: UITree) -> UIPoint? {
        points(in: tree, limit: 1).first
    }

    /// A hide keyboard control, then space above the topmost field taking turns with space up from the keys, clear of every field and of `tried`.
    public static func points(in tree: UITree, fields: [UIFrame] = [], tried: [UIPoint] = [], limit: Int = attempts) -> [UIPoint] {
        let nodes = tree.roots.flatMap { $0.flattened() }
        guard nodes.contains(where: { $0.role == .keyboard && ($0.frame?.height ?? 0) > 0 }) else { return [] }
        var offered: [UIPoint] = []
        if let hide = nodes.first(where: isHideControl), let frame = hide.frame, frame.width > 0, frame.height > 0 {
            offered.append(frame.center)
        }
        let keys = coverageFrames(in: tree)
        if let top = keys.map(\.y).min(), let viewport = tree.viewport {
            let avoid = keys + fields.map { $0.outset(by: fieldMargin) }
            let aboveForm = fields.map(\.y).min().map { scan(tree, from: $0 - fieldMargin - 8, viewport: viewport, avoiding: avoid) } ?? []
            let nearKeys = scan(tree, from: top - 24, viewport: viewport, avoiding: avoid)
            for index in 0..<max(aboveForm.count, nearKeys.count) {
                if index < aboveForm.count { offered.append(aboveForm[index]) }
                if index < nearKeys.count { offered.append(nearKeys[index]) }
            }
        }
        var chosen: [UIPoint] = []
        for point in offered where chosen.count < limit {
            if (tried + chosen).allSatisfy({ distance($0, point) >= spacing }) { chosen.append(point) }
        }
        return chosen
    }

    /// One point per row outside `avoid`, from `start` up to the top of the screen: empty space first, then inert text.
    private static func scan(_ tree: UITree, from start: Double, viewport: UIFrame, avoiding avoid: [UIFrame]) -> [UIPoint] {
        let xs = [viewport.x + viewport.width * 0.5, viewport.x + 40, viewport.x + viewport.width - 40]
            .filter { $0 >= viewport.x && $0 < viewport.x + viewport.width }
        var found: [UIPoint] = []
        for backgroundOnly in [true, false] {
            var y = start
            while y > viewport.y + 8 {
                let row = xs.lazy.map { UIPoint(x: $0, y: y) }.first { point in
                    guard !avoid.contains(where: { $0.contains(point) }) else { return false }
                    let chain = chain(in: tree.roots, at: point, viewport: viewport)
                    guard let hit = chain.last, hit.role != .keyboard, !SignInHit.isHiddenByChrome(chain) else { return false }
                    if chain.contains(where: \.isActionable) { return false }
                    return backgroundOnly ? isBackground(hit) : isSafe(hit)
                }
                if let row { found.append(row) }
                y -= 36
            }
        }
        return found
    }

    private static func distance(_ lhs: UIPoint, _ rhs: UIPoint) -> Double {
        ((lhs.x - rhs.x) * (lhs.x - rhs.x) + (lhs.y - rhs.y) * (lhs.y - rhs.y)).squareRoot()
    }

    /// The keys, not a keyboard window that spans the screen around them.
    public static func covers(_ point: UIPoint, in tree: UITree) -> Bool {
        coverageFrames(in: tree).contains { $0.contains(point) }
    }

    /// True when the keys span most of the screen's width and a fifth of its height, as a docked keyboard's do; a toolbar shown for a
    /// hardware keyboard does not, and Back then goes to the app instead of hiding it.
    public static func showsKeys(in tree: UITree) -> Bool {
        guard let viewport = tree.viewport, viewport.width > 0, viewport.height > 0 else { return true }
        return coverageFrames(in: tree).contains { $0.width >= 0.6 * viewport.width && $0.height >= 0.2 * viewport.height }
    }

    static func coverageFrames(in tree: UITree) -> [UIFrame] {
        let keyboards = tree.roots.flatMap { $0.flattened() }.filter { $0.role == .keyboard && ($0.frame?.height ?? 0) > 0 }
        guard let viewport = tree.viewport else { return keyboards.compactMap(\.frame) }
        return keyboards.compactMap { keyboard in
            guard let frame = keyboard.frame else { return nil }
            let keys = keyboard.flattened().compactMap(\.frame).filter { candidate in
                candidate.width > 0 && candidate.height > 0 && candidate != frame && !isBackdrop(candidate, in: viewport)
            }
            return union(keys) ?? frame
        }
    }

    private static func union(_ frames: [UIFrame]) -> UIFrame? {
        guard let first = frames.first else { return nil }
        return frames.dropFirst().reduce(first) { box, frame in
            let left = min(box.x, frame.x)
            let top = min(box.y, frame.y)
            return UIFrame(
                x: left,
                y: top,
                width: max(box.x + box.width, frame.x + frame.width) - left,
                height: max(box.y + box.height, frame.y + frame.height) - top
            )
        }
    }

    /// A screen-sized keyboard window is not a tap target: the form behind it is.
    private static func chain(in nodes: [UINode], at point: UIPoint, viewport: UIFrame) -> [UINode] {
        for node in nodes.reversed() {
            if isBackdropKeyboard(node, in: viewport) { continue }
            if let found = chain(from: node, at: point, viewport: viewport) {
                return found
            }
        }
        return []
    }

    private static func chain(from node: UINode, at point: UIPoint, viewport: UIFrame) -> [UINode]? {
        for child in node.children.reversed() {
            if isBackdropKeyboard(child, in: viewport) { continue }
            if let found = chain(from: child, at: point, viewport: viewport) {
                return [node] + found
            }
        }
        guard let frame = node.frame, frame.contains(point) else { return nil }
        return [node]
    }

    private static func isBackdropKeyboard(_ node: UINode, in viewport: UIFrame) -> Bool {
        guard node.role == .keyboard, let frame = node.frame else { return false }
        return isBackdrop(frame, in: viewport)
    }

    /// Covers at least 80 percent of the viewport, as the keyboard's own window does around a strip of keys.
    private static func isBackdrop(_ frame: UIFrame, in viewport: UIFrame) -> Bool {
        guard let visible = frame.intersection(viewport), viewport.width > 0, viewport.height > 0 else { return false }
        return visible.width * visible.height >= 0.8 * viewport.width * viewport.height
    }

    private static func isHideControl(_ node: UINode) -> Bool {
        guard node.role == .button || node.role == .other, node.frame != nil else { return false }
        let text = [node.label, node.id].compactMap { $0?.lowercased() }.joined(separator: " ")
        return text.contains("hide keyboard") || text.contains("dismiss keyboard")
    }

    /// Empty space: a window or an unlabelled container, never text a link might hide behind.
    private static func isBackground(_ node: UINode) -> Bool {
        switch node.role {
        case .application, .window:
            return true
        case .group, .other:
            return node.label?.isEmpty != false
        case .scrollView:
            return node.label?.isEmpty != false && (node.frame?.height ?? 0) >= 160
        default:
            return false
        }
    }

    private static func isSafe(_ node: UINode) -> Bool {
        switch node.role {
        case .text, .header, .group, .other, .application, .image, .window:
            return true
        case .scrollView:
            return (node.frame?.height ?? 0) >= 160
        default:
            return false
        }
    }
}

private extension UIFrame {
    func outset(by margin: Double) -> UIFrame {
        UIFrame(x: x - margin, y: y - margin, width: width + 2 * margin, height: height + 2 * margin)
    }
}
