import Foundation

extension UITree {
    /// The deepest node whose frame contains `point`, through the topmost sibling at each level; nil outside every root.
    public func deepestNode(at point: UIPoint) -> UINode? {
        hitChain(at: point).last
    }

    /// The nodes from a root down to `deepestNode(at:)`; empty outside every root.
    public func hitChain(at point: UIPoint) -> [UINode] {
        Self.hitChain(in: roots, at: point)
    }

    /// `hitChain(at:)` over `roots`, taking roots and siblings top first and skipping nodes Android hides from the user.
    public static func hitChain(in roots: [UINode], at point: UIPoint) -> [UINode] {
        for root in topFirstRoots(roots) {
            if let chain = hitChain(from: root, at: point, parentHidden: true) {
                return chain
            }
        }
        return []
    }

    /// Siblings top first: by Android drawing order when every sibling has one, else the last listed first.
    public static func topFirst(_ siblings: [UINode]) -> [UINode] {
        guard siblings.count > 1, let orders = drawingOrders(of: siblings) else {
            return siblings.reversed()
        }
        return siblings.indices.sorted { orders[$0] != orders[$1] ? orders[$0] > orders[$1] : $0 > $1 }.map { siblings[$0] }
    }

    /// Roots top first: by window layer when every root has one, else the last listed first.
    static func topFirstRoots(_ roots: [UINode]) -> [UINode] {
        let layers = roots.compactMap(\.windowLayer)
        guard roots.count > 1, layers.count == roots.count else {
            return roots.reversed()
        }
        return roots.indices.sorted { layers[$0] != layers[$1] ? layers[$0] > layers[$1] : $0 > $1 }.map { roots[$0] }
    }

    /// Each sibling's Android drawing order, or nil when any lacks one.
    static func drawingOrders(of siblings: [UINode]) -> [Int]? {
        let orders = siblings.compactMap(\.drawingOrder)
        return orders.count == siblings.count ? orders : nil
    }

    /// Whether `upper` is drawn over `lower` (a descendant over its ancestor), and whether more than tree order decided; nil when either is missing.
    public static func zOrder(of upper: UINode, over lower: UINode, in roots: [UINode]) -> (isAbove: Bool, byDrawingOrder: Bool)? {
        guard let upperPath = indexPath(to: upper, in: roots), let lowerPath = indexPath(to: lower, in: roots) else {
            return nil
        }
        guard upperPath[0] == lowerPath[0] else {
            let layers = roots.compactMap(\.windowLayer)
            if layers.count == roots.count, layers[upperPath[0]] != layers[lowerPath[0]] {
                return (layers[upperPath[0]] > layers[lowerPath[0]], true)
            }
            return (upperPath[0] > lowerPath[0], false)
        }
        var parent = roots[upperPath[0]]
        var depth = 1
        while depth < upperPath.count, depth < lowerPath.count, upperPath[depth] == lowerPath[depth] {
            parent = parent.children[upperPath[depth]]
            depth += 1
        }
        guard depth < upperPath.count, depth < lowerPath.count else {
            return (upperPath.count > lowerPath.count, true)
        }
        let upperIndex = upperPath[depth], lowerIndex = lowerPath[depth]
        if let orders = drawingOrders(of: parent.children), orders[upperIndex] != orders[lowerIndex] {
            return (orders[upperIndex] > orders[lowerIndex], true)
        }
        return (upperIndex > lowerIndex, false)
    }

    /// Child indexes from `roots` down to `node`, the first picking the root; nil when it is not there.
    public static func indexPath(to node: UINode, in roots: [UINode]) -> [Int]? {
        for (index, root) in roots.enumerated() {
            if let path = indexPath(to: node, from: root) {
                return [index] + path
            }
        }
        return nil
    }

    private static func indexPath(to node: UINode, from current: UINode) -> [Int]? {
        if current.isSameElement(as: node) {
            return []
        }
        for (index, child) in current.children.enumerated() {
            if let path = indexPath(to: node, from: child) {
                return [index] + path
            }
        }
        return nil
    }

    /// A node Android hides from the user takes no touch, unless its parent or window is hidden too, as a whole app is behind a floating keyboard.
    private static func hitChain(from node: UINode, at point: UIPoint, parentHidden: Bool) -> [UINode]? {
        let hidden = node.visibleToUser == false
        if hidden, !parentHidden {
            return nil
        }
        for child in topFirst(node.children) {
            if let chain = hitChain(from: child, at: point, parentHidden: hidden) {
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

    /// Android's z-order among the node's siblings; nil on iOS or when the dump gave none.
    public var drawingOrder: Int? {
        if case .android(let attributes) = native { return attributes.drawingOrder }
        return nil
    }

    /// The window layer on an Android window's root; nil elsewhere.
    public var windowLayer: Int? {
        if case .android(let attributes) = native { return attributes.windowLayer }
        return nil
    }

    /// Android's visible-to-user flag; nil on iOS.
    public var visibleToUser: Bool? {
        if case .android(let attributes) = native { return attributes.visibleToUser }
        return nil
    }
}
