import Foundation

extension UITree {
    /// The deepest node whose frame contains `point`, preferring later (topmost) siblings; nil outside every root.
    public func deepestNode(at point: UIPoint) -> UINode? {
        for root in roots.reversed() {
            if let hit = Self.deepestNode(in: root, at: point) {
                return hit
            }
        }
        return nil
    }

    private static func deepestNode(in node: UINode, at point: UIPoint) -> UINode? {
        for child in node.children.reversed() {
            if let hit = deepestNode(in: child, at: point) {
                return hit
            }
        }
        guard let frame = node.frame,
              point.x >= frame.x, point.x < frame.x + frame.width,
              point.y >= frame.y, point.y < frame.y + frame.height else {
            return nil
        }
        return node
    }
}
