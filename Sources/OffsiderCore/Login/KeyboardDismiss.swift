import Foundation

/// A point that resigns the software keyboard without pressing a key or a control.
public enum KeyboardDismiss {
    /// Empty space above the keys first, then inert text. Nil when there is no keyboard, or every point is a control.
    public static func point(in tree: UITree) -> UIPoint? {
        let nodes = tree.roots.flatMap { $0.flattened() }
        let keyboards = nodes.filter { $0.role == .keyboard && ($0.frame?.height ?? 0) > 0 }
        guard !keyboards.isEmpty else { return nil }
        if let hide = nodes.first(where: isHideControl), let frame = hide.frame, frame.width > 0, frame.height > 0 {
            return frame.center
        }
        guard let top = coverageFrames(in: tree).map(\.y).min(), let viewport = tree.viewport else { return nil }
        let xs = [viewport.x + viewport.width * 0.5, viewport.x + 40, viewport.x + viewport.width - 40]
            .filter { $0 >= viewport.x && $0 < viewport.x + viewport.width }
        for backgroundOnly in [true, false] {
            var y = top - 24
            while y > viewport.y + 8 {
                for x in xs {
                    let point = UIPoint(x: x, y: y)
                    let chain = chain(in: tree.roots, at: point, viewport: viewport)
                    guard let hit = chain.last, hit.role != .keyboard, !SignInHit.isHiddenByChrome(chain) else { continue }
                    if chain.contains(where: \.isActionable) { continue }
                    if backgroundOnly ? isBackground(hit) : isSafe(hit) { return point }
                }
                y -= 36
            }
        }
        return nil
    }

    /// The keys, not a keyboard window that spans the screen around them.
    public static func covers(_ point: UIPoint, in tree: UITree) -> Bool {
        coverageFrames(in: tree).contains { $0.contains(point) }
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
