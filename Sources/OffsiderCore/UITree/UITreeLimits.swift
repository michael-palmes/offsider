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

    /// `note` for `Console`: an agent reads it as it is, a person in fewer words.
    public var notice: Notice {
        let cut = [depth ? "\(UITreeLimits.maxDepth) levels" : nil, nodes ? "\(UITreeLimits.maxNodes.formatted()) elements" : nil].compactMap { $0 }
        return .note("Tree cut at \(cut.joined(separator: " and ")); some elements are not listed", agent: String(note.dropFirst("Note: ".count)))
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

extension UITreeLimits {
    /// Maps a source tree without recursion: `shallow` maps one element (depth 1 is the root) and `children` lists its children.
    /// Mapping stops one level past `maxDepth`, so a deep tree cannot exhaust the stack and `limit` still notes the cut.
    public static func map<Source>(_ root: Source, maxDepth: Int = maxDepth, shallow: (Source, Int) -> UINode, children: (Source) -> [Source]) -> UINode {
        func level(_ source: Source, depth: Int) -> MappingLevel<Source> {
            MappingLevel(node: shallow(source, depth), sources: depth > maxDepth ? [] : children(source))
        }
        var stack = [level(root, depth: 1)]
        while let last = stack.indices.last {
            if stack[last].next < stack[last].sources.count {
                let source = stack[last].sources[stack[last].next]
                stack[last].next += 1
                stack.append(level(source, depth: stack.count + 1))
                continue
            }
            var done = stack.removeLast()
            done.node.children = done.mapped
            guard let parent = stack.indices.last else { return done.node }
            stack[parent].mapped.append(done.node)
        }
        preconditionFailure("the root is always on the stack")
    }
}

/// One element `UITreeLimits.map` is mapping: its children still to visit and those already mapped.
private struct MappingLevel<Source> {
    var node: UINode
    var sources: [Source]
    var next = 0
    var mapped: [UINode] = []
}
