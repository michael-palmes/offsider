import Foundation

/// The system scroll indicator iOS lists as a slider inside a scroll view. It takes no taps, so it never covers a target; its label is localised, so only its shape and place tell it apart.
public enum ScrollIndicator {
    /// iOS reports 30 pt; a real slider's track is taller.
    static let maximumThickness = 34.0
    /// iOS insets it 3 pt from its scroll view's edge.
    static let edgeTolerance = 5.0
    static let containers: Set<UIRole> = [.scrollView, .list]

    /// A slider with no id, at most 34 pt thick, along `parent`'s right edge (upright) or bottom edge (across), where `parent` is a scroll view or list.
    public static func isIndicator(_ node: UINode, parent: UINode?) -> Bool {
        guard let parent, containers.contains(parent.role), let edges = parent.frame else { return false }
        return lies(node, along: edges)
    }

    /// For a node read apart from its tree, such as a hit-test's answer: an indicator of any scroll view or list in `roots`.
    public static func isIndicator(_ node: UINode, alongAnyScrollViewIn roots: [UINode]) -> Bool {
        roots.contains { root in
            root.flattened().contains { container in
                containers.contains(container.role) && container.frame.map { lies(node, along: $0) } == true
            }
        }
    }

    /// Every scroll indicator in `roots`, in tree order.
    public static func all(in roots: [UINode]) -> [UINode] {
        var found: [UINode] = []
        func visit(_ node: UINode, parent: UINode?) {
            if isIndicator(node, parent: parent) {
                found.append(node)
            }
            for child in node.children {
                visit(child, parent: node)
            }
        }
        for root in roots {
            visit(root, parent: nil)
        }
        return found
    }

    /// A physical iPhone lists the indicator as a labelled element of no known type rather than a slider.
    private static func hasIndicatorRole(_ node: UINode) -> Bool {
        node.role == .slider || (node.role == .other && node.normalizedLabel != nil)
    }

    private static func lies(_ node: UINode, along edges: UIFrame) -> Bool {
        guard hasIndicatorRole(node), node.normalizedID == nil, let frame = node.frame, frame.width > 0, frame.height > 0 else { return false }
        if frame.width <= frame.height {
            return frame.width <= maximumThickness && abs(edges.x + edges.width - (frame.x + frame.width)) <= edgeTolerance
        }
        return frame.height <= maximumThickness && abs(edges.y + edges.height - (frame.y + frame.height)) <= edgeTolerance
    }
}
