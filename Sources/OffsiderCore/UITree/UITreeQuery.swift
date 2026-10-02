import Foundation

/// Node filters for `describe-ui`; every enabled filter must match.
public struct UITreeFilter: Equatable, Sendable {
    public var onScreen: Bool
    public var labelled: Bool
    public var actionable: Bool

    public init(onScreen: Bool = false, labelled: Bool = false, actionable: Bool = false) {
        self.onScreen = onScreen
        self.labelled = labelled
        self.actionable = actionable
    }

    public var isEmpty: Bool {
        !onScreen && !labelled && !actionable
    }

    /// Whether `node` itself passes; a nil `visibleRect` makes `onScreen` keep everything.
    /// On screen means at least 1 pt visible on both axes, the rule selectors, `wait` and `assert` use.
    public func matches(_ node: UINode, visibleRect: UIFrame?) -> Bool {
        if onScreen, let visibleRect {
            guard let frame = node.frame, frame.isVisible(in: visibleRect) else {
                return false
            }
        }
        if labelled, ![node.label, node.id, node.value].contains(where: Self.hasText) {
            return false
        }
        if actionable, !node.isActionable {
            return false
        }
        return true
    }

    private static func hasText(_ value: String?) -> Bool {
        guard let value else { return false }
        return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// One node in flat output: `index` and `parent` are positions in that output, `depth` is the depth in the full tree.
public struct UIFlatEntry: Equatable, Sendable {
    public let index: Int
    public let parent: Int?
    public let depth: Int
    /// The node without its children.
    public let node: UINode

    public init(index: Int, parent: Int?, depth: Int, node: UINode) {
        self.index = index
        self.parent = parent
        self.depth = depth
        self.node = node
    }
}

extension UINode {
    /// An actionable role, or an iOS element with custom actions.
    public var isActionable: Bool {
        if role.isActionable {
            return true
        }
        if case .ios(let attributes) = native {
            return !attributes.customActions.isEmpty
        }
        return false
    }
}

extension UITree {
    /// The viewport selectors use, else the screen in the tree's coordinates, else the application frame.
    public var visibleRect: UIFrame? {
        if let viewport {
            return viewport
        }
        if let screen {
            return UIFrame(x: 0, y: 0, width: screen.width, height: screen.height)
        }
        return applicationFrame
    }

    /// Matching nodes plus their ancestors, nesting kept.
    public func filtered(_ filter: UITreeFilter) -> UITree {
        guard !filter.isEmpty else {
            return self
        }
        let rect = visibleRect
        var copy = self
        copy.roots = roots.compactMap { Self.prune($0, filter, rect) }
        return copy
    }

    /// Matching nodes in pre-order (the order of `UINode.flattened()`), each pointing at its nearest kept ancestor.
    public func flatEntries(_ filter: UITreeFilter) -> [UIFlatEntry] {
        let rect = visibleRect
        var entries: [UIFlatEntry] = []
        for root in roots {
            Self.collect(root, depth: 0, parent: nil, filter, rect, into: &entries)
        }
        return entries
    }

    private static func prune(_ node: UINode, _ filter: UITreeFilter, _ rect: UIFrame?) -> UINode? {
        var copy = node
        copy.children = node.children.compactMap { prune($0, filter, rect) }
        guard !copy.children.isEmpty || filter.matches(node, visibleRect: rect) else {
            return nil
        }
        return copy
    }

    private static func collect(
        _ node: UINode,
        depth: Int,
        parent: Int?,
        _ filter: UITreeFilter,
        _ rect: UIFrame?,
        into entries: inout [UIFlatEntry]
    ) {
        var nearest = parent
        if filter.matches(node, visibleRect: rect) {
            var leaf = node
            leaf.children = []
            nearest = entries.count
            entries.append(UIFlatEntry(index: entries.count, parent: parent, depth: depth, node: leaf))
        }
        for child in node.children {
            collect(child, depth: depth + 1, parent: nearest, filter, rect, into: &entries)
        }
    }
}
