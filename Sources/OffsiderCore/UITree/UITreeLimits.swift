import Foundation

/// Which of `UITreeLimits` a tree hit, so `describe-ui` can say what is missing.
public struct UITreeTruncation: Equatable, Sendable {
    /// Children below `maxDepth` levels were dropped.
    public var depth: Bool
    /// Elements after the first `maxNodes` were dropped.
    public var nodes: Bool

    public init(depth: Bool = false, nodes: Bool = false) {
        self.depth = depth
        self.nodes = nodes
    }

    /// One line for stderr.
    public var note: String {
        var parts: [String] = []
        if depth { parts.append("\(UITreeLimits.maxDepth) levels deep") }
        if nodes { parts.append("\(UITreeLimits.maxNodes.formatted()) elements") }
        return "Note: the tree was cut at \(parts.joined(separator: " and ")), so some elements are not listed."
    }
}

/// The most of a tree Offsider keeps, whatever a device or file sends.
public enum UITreeLimits {
    public static let maxDepth = 64
    public static let maxNodes = 50_000

    /// `roots` unchanged when within the limits; else a copy cut to them, in reading order, with what was hit.
    public static func limit(_ roots: [UINode], maxDepth: Int = maxDepth, maxNodes: Int = maxNodes) -> (roots: [UINode], truncation: UITreeTruncation?) {
        var counted = 0
        var hit = UITreeTruncation()
        scan(roots, depth: 1, maxDepth: maxDepth, maxNodes: maxNodes, counted: &counted, hit: &hit)
        guard hit.depth || hit.nodes else { return (roots, nil) }
        var kept = 0
        return (trim(roots, depth: 1, maxDepth: maxDepth, maxNodes: maxNodes, kept: &kept), hit)
    }

    private static func scan(_ nodes: [UINode], depth: Int, maxDepth: Int, maxNodes: Int, counted: inout Int, hit: inout UITreeTruncation) {
        for node in nodes {
            guard counted < maxNodes else {
                hit.nodes = true
                return
            }
            counted += 1
            guard !node.children.isEmpty else { continue }
            if depth >= maxDepth {
                hit.depth = true
            } else {
                scan(node.children, depth: depth + 1, maxDepth: maxDepth, maxNodes: maxNodes, counted: &counted, hit: &hit)
            }
        }
    }

    private static func trim(_ nodes: [UINode], depth: Int, maxDepth: Int, maxNodes: Int, kept: inout Int) -> [UINode] {
        var result: [UINode] = []
        for var node in nodes {
            guard kept < maxNodes else { break }
            kept += 1
            node.children = depth >= maxDepth ? [] : trim(node.children, depth: depth + 1, maxDepth: maxDepth, maxNodes: maxNodes, kept: &kept)
            result.append(node)
        }
        return result
    }
}
