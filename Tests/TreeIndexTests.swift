import Foundation
@testable import OffsiderCore
import Testing

/// The index the on-screen judgement reads a tree through answers as a walk of the tree does, so judging faster never judges differently.
@Suite("Tree index")
struct TreeIndexTests {
    static let trees: [UITree] = ((try? TreeGoldens.all().map(TreeGoldens.tree(of:))) ?? []) + FrontFixtures.all.map { $0.tree() } + [copiesAndOddFrames()]

    /// The same Back button on two pages, and a node whose frame is not a number, which equals nothing, itself included.
    static func copiesAndOddFrames() -> UITree {
        let back = FakeUI.node(.button, id: "back", label: "Back", frame: FakeUI.frame(0, 40, 60, 44))
        let page = { (id: String) in FakeUI.node(.other, id: id, frame: FakeUI.frame(0, 0, 402, 874), children: [back, FakeUI.node(.text, label: "Title")]) }
        let odd = FakeUI.node(.text, label: "Odd", frame: FakeUI.frame(.nan, 10, 20, 20))
        return FakeUI.tree([page("page-1"), page("page-2"), odd])
    }

    @Test("the index finds every copy, ancestor and path a walk finds, for every node of every tree")
    func lookupsMatchAWalk() {
        #expect(Self.trees.count > 40)
        for tree in Self.trees {
            let index = TreeIndex(roots: tree.roots)
            let flat = tree.roots.flatMap { $0.flattened() }
            // A frame that is not a number equals nothing, so the lists are compared by what identifies each place.
            #expect(index.nodes.map { [$0.role.rawValue, $0.id, $0.label, "\($0.children.count)"] } == flat.map { [$0.role.rawValue, $0.id, $0.label, "\($0.children.count)"] })
            for (position, node) in flat.enumerated() {
                let copies = ScreenStack.indexes(of: node, in: tree.roots)
                #expect(index.indexes(of: node) == copies)
                #expect(index.firstIndex(of: node) == copies.first)
                #expect(index.firstIndex(at: position) == copies.first)
                #expect(index.ancestors(of: node) == Self.ancestors(of: node, in: tree.roots))
                if let path = UITree.indexPath(to: node, in: tree.roots), let first = copies.first {
                    #expect(index.indexPath(to: first) == path)
                    #expect(index.index(at: path) == UITree.preorderIndex(of: path, in: tree.roots))
                }
            }
        }
    }

    /// The ancestors of the first copy of `node`, walking down from the roots.
    static func ancestors(of node: UINode, in roots: [UINode]) -> [UINode] {
        guard let path = UITree.indexPath(to: node, in: roots) else { return [] }
        return Array(UITree.nodes(along: path, in: roots).dropLast())
    }

    @Test("a hit path through the index is the walk's at every point of every tree, with a branch left out too")
    func hitPathsMatchAWalk() {
        for tree in Self.trees {
            guard let viewport = tree.viewport else { continue }
            let index = TreeIndex(roots: tree.roots)
            for row in 0...40 {
                for column in 0...20 {
                    let point = UIPoint(x: viewport.x + viewport.width * Double(column) / 20, y: viewport.y + viewport.height * Double(row) / 40)
                    let path = UITree.hitPath(in: tree.roots, at: point)
                    #expect(UITree.hitPath(in: index, at: point) == path)
                    guard path.count > 1 else { continue }
                    let skipping: Set<[Int]> = [Array(path.dropLast())]
                    #expect(UITree.hitPath(in: index, at: point, skipping: skipping) == UITree.hitPath(in: tree.roots, at: point, skipping: skipping))
                }
            }
        }
    }
}
