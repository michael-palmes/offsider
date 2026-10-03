import Foundation

extension UITree {
    /// The deepest node whose frame contains `point`, preferring later (topmost) siblings; nil outside every root.
    public func deepestNode(at point: UIPoint) -> UINode? {
        hitChain(at: point).last
    }

    /// The nodes from a root down to `deepestNode(at:)`; empty outside every root.
    public func hitChain(at point: UIPoint) -> [UINode] {
        Self.hitChain(in: roots, at: point)
    }

    /// `hitChain(at:)` over `roots`, where later roots win as later siblings do.
    public static func hitChain(in roots: [UINode], at point: UIPoint) -> [UINode] {
        for root in roots.reversed() {
            if let chain = hitChain(from: root, at: point) {
                return chain
            }
        }
        return []
    }

    private static func hitChain(from node: UINode, at point: UIPoint) -> [UINode]? {
        for child in node.children.reversed() {
            if let chain = hitChain(from: child, at: point) {
                return [node] + chain
            }
        }
        guard let frame = node.frame, frame.contains(point) else {
            return nil
        }
        return [node]
    }
}

extension UINode {
    /// Compares every field but the children, so a copy of a node still identifies it in its tree.
    public func isSameElement(as other: UINode) -> Bool {
        role == other.role
            && id == other.id
            && label == other.label
            && value == other.value
            && frame == other.frame
            && enabled == other.enabled
            && state == other.state
            && native == other.native
    }
}
