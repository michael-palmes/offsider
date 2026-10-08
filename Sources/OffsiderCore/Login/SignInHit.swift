import Foundation

/// Where a sign-in control sits, once the software keyboard and empty containers are left out of the hit test.
enum SignInHit {
    /// True when `chain` runs through the software keyboard or the bar above it.
    static func isHiddenByChrome(_ chain: [UINode]) -> Bool {
        chain.contains(where: isChrome)
    }

    static func chain(in tree: UITree, at point: UIPoint) -> [UINode] {
        let roots = tree.roots.map(classify)
        for root in roots.reversed() {
            if let found = chain(from: root, at: point) { return found }
        }
        return []
    }

    private enum Kind {
        case chrome
        case app
        case passthrough
    }

    private struct Classified {
        var node: UINode
        var kind: Kind
        var children: [Classified]
    }

    private static func classify(_ node: UINode) -> Classified {
        if isChrome(node) {
            return Classified(node: node, kind: .chrome, children: [])
        }
        let children = node.children.map(classify)
        let kind: Kind
        if children.contains(where: { $0.kind == .app }) {
            kind = .app
        } else if children.contains(where: { $0.kind == .chrome }) {
            kind = .chrome
        } else if isStructural(node.role) {
            kind = .passthrough
        } else {
            kind = .app
        }
        return Classified(node: node, kind: kind, children: children)
    }

    /// The software keyboard, and the bar iOS draws above it (`SystemInputAssistantView`).
    static func isChrome(_ node: UINode) -> Bool {
        if node.role == .keyboard { return true }
        guard let id = node.id else { return false }
        return id.hasPrefix(IOSAccessibilityMapping.keyboardLayoutPrefix) || id.hasPrefix("SystemInputAssistant")
    }

    private static func isStructural(_ role: UIRole) -> Bool {
        switch role {
        case .application, .window, .group, .other, .scrollView:
            return true
        default:
            return false
        }
    }

    private static func chain(from item: Classified, at point: UIPoint) -> [UINode]? {
        if item.kind != .app { return nil }
        for child in item.children.reversed() {
            if let nested = chain(from: child, at: point) {
                return [item.node] + nested
            }
        }
        guard let frame = item.node.frame, frame.contains(point) else { return nil }
        return [item.node]
    }
}
