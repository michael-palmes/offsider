import Foundation

/// A tree read once in pre-order, as `flattened()` lists it, so judging many of its elements finds each one, its copies and its ancestors without walking the tree again.
public struct TreeIndex: Sendable {
    public let roots: [UINode]
    /// Every node in pre-order.
    public let nodes: [UINode]
    let flat: FlatTree
    /// Each node's place among its siblings, a root's among the roots.
    private let positions: [Int]
    /// The pre-order index of each root.
    private let rootIndexes: [Int]
    /// True for a keyboard and everything inside one.
    private let inKeyboard: [Bool]
    /// Pre-order indexes by what `isSameElement` compares, first first.
    private let copies: [Key: [Int]]
    /// Each node's first identical node; nil for one identical to none, itself included.
    private let firsts: [Int?]
    /// The edges of every frame in each node's branch, so a point none of them holds passes the branch by.
    private let reaches: [Reach?]

    public init(roots: [UINode]) {
        let flat = FlatTree(roots: roots)
        let nodes = flat.entries.map(\.node)
        var positions = [Int](repeating: 0, count: nodes.count)
        var inKeyboard = [Bool](repeating: false, count: nodes.count)
        var copies: [Key: [Int]] = [:]
        var firsts = [Int?](repeating: nil, count: nodes.count)
        var rootIndexes: [Int] = []
        for (index, entry) in flat.entries.enumerated() {
            if let parent = entry.parent {
                inKeyboard[index] = entry.node.role == .keyboard || inKeyboard[parent]
            } else {
                inKeyboard[index] = entry.node.role == .keyboard
                positions[index] = rootIndexes.count
                rootIndexes.append(index)
            }
            for (position, child) in entry.children.enumerated() {
                positions[child] = position
            }
            let key = Key(entry.node)
            firsts[index] = (copies[key] ?? []).first { nodes[$0].isSameElement(as: entry.node) } ?? (entry.node.isSameElement(as: entry.node) ? index : nil)
            copies[key, default: []].append(index)
        }
        self.roots = roots
        self.nodes = nodes
        self.flat = flat
        self.positions = positions
        self.rootIndexes = rootIndexes
        self.inKeyboard = inKeyboard
        self.copies = copies
        self.firsts = firsts
        var reaches = [Reach?](repeating: nil, count: nodes.count)
        for (index, entry) in flat.entries.enumerated().reversed() {
            reaches[index] = entry.children.reduce(Reach(entry.node.frame)) { Reach.union($0, reaches[$1]) }
        }
        self.reaches = reaches
    }

    /// The pre-order index of the node `path` leads to, as `UITree.preorderIndex(of:in:)` counts it.
    public func index(at path: [Int]) -> Int {
        guard let first = path.first else { return 0 }
        var index = rootIndexes[first]
        for child in path.dropFirst() {
            index = flat.entries[index].children[child]
        }
        return index
    }

    /// Pre-order indexes of the children of the node at `index`.
    func children(of index: Int) -> [Int] {
        flat.entries[index].children
    }

    /// False only when no frame in the branch at `index` holds `point`.
    func mayHold(_ point: UIPoint, at index: Int) -> Bool {
        reaches[index]?.mayHold(point) == true
    }

    /// The left and top edges and the far edges of a set of frames, each far edge added as `UIFrame.contains` adds it.
    private struct Reach: Sendable {
        let left: Double
        let top: Double
        let right: Double
        let bottom: Double

        /// Nil for a frame no point can lie in.
        init?(_ frame: UIFrame?) {
            guard let frame else { return nil }
            let right = frame.x + frame.width, bottom = frame.y + frame.height
            guard !frame.x.isNaN, !frame.y.isNaN, !right.isNaN, !bottom.isNaN else { return nil }
            self.init(left: frame.x, top: frame.y, right: right, bottom: bottom)
        }

        private init(left: Double, top: Double, right: Double, bottom: Double) {
            self.left = left
            self.top = top
            self.right = right
            self.bottom = bottom
        }

        static func union(_ a: Reach?, _ b: Reach?) -> Reach? {
            guard let a else { return b }
            guard let b else { return a }
            return Reach(left: min(a.left, b.left), top: min(a.top, b.top), right: max(a.right, b.right), bottom: max(a.bottom, b.bottom))
        }

        func mayHold(_ point: UIPoint) -> Bool {
            point.x >= left && point.x < right && point.y >= top && point.y < bottom
        }
    }

    /// Pre-order indexes of every node identical to `node`, first first; empty when the tree holds none.
    public func indexes(of node: UINode) -> [Int] {
        copies[Key(node)]?.filter { nodes[$0].isSameElement(as: node) } ?? []
    }

    /// The pre-order index of the first node identical to `node`; nil when the tree holds none.
    public func firstIndex(of node: UINode) -> Int? {
        copies[Key(node)]?.first { nodes[$0].isSameElement(as: node) }
    }

    /// `firstIndex(of:)` for the node at `index`, without hashing it again.
    public func firstIndex(at index: Int) -> Int? {
        firsts[index]
    }

    /// The pre-order index of the node holding the node at `index`; nil for a root.
    public func parent(of index: Int) -> Int? {
        flat.entries[index].parent
    }

    /// The node at `index` with everything inside it, as pre-order indexes.
    public func subtree(_ index: Int) -> Range<Int> {
        flat.subtree(index)
    }

    /// The nodes from its root down to the node at `index`, both included.
    public func chain(to index: Int) -> [UINode] {
        lineage(of: index).map { nodes[$0] }
    }

    /// `chain(to:)` as pre-order indexes.
    public func lineage(of index: Int) -> [Int] {
        var lineage: [Int] = []
        var current: Int? = index
        while let at = current {
            lineage.append(at)
            current = flat.entries[at].parent
        }
        return lineage.reversed()
    }

    /// Child indexes from the roots down to the node at `index`, the first picking the root, as `UITree.indexPath(to:in:)` gives them.
    public func indexPath(to index: Int) -> [Int] {
        var path: [Int] = []
        var current: Int? = index
        while let at = current {
            path.append(positions[at])
            current = flat.entries[at].parent
        }
        return path.reversed()
    }

    /// The ancestors of the first node identical to `node`, its root first; empty when the tree holds none.
    public func ancestors(of node: UINode) -> [UINode] {
        firstIndex(of: node).map { Array(chain(to: $0).dropLast()) } ?? []
    }

    /// True when the node at `index` is a keyboard or sits inside one.
    public func isInKeyboard(_ index: Int) -> Bool {
        inKeyboard[index]
    }

    /// True when `node` is a keyboard or the first node identical to it sits inside one.
    public func isUnderKeyboard(_ node: UINode) -> Bool {
        node.role == .keyboard || firstIndex(of: node).map(isInKeyboard) == true
    }

    /// The index among `roots` of the root holding the node at `index`.
    public func root(of index: Int) -> Int {
        var current = index
        while let parent = flat.entries[current].parent {
            current = parent
        }
        return positions[current]
    }

    /// The fields `isSameElement` compares that hash cheaply, so identical elements share a key.
    private struct Key: Hashable {
        let role: UIRole
        let id: String?
        let label: String?
        let value: String?
        let x: Double?
        let y: Double?
        let width: Double?
        let height: Double?

        init(_ node: UINode) {
            role = node.role
            id = node.id
            label = node.label
            value = node.value
            x = node.frame?.x
            y = node.frame?.y
            width = node.frame?.width
            height = node.frame?.height
        }
    }
}
