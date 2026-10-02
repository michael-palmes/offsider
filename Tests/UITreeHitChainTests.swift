import Foundation
import OffsiderCore
import Testing

@Suite("UITree hit chain")
struct UITreeHitChainTests {
    private static func node(_ id: String, _ x: Double, _ y: Double, _ width: Double, _ height: Double, children: [UINode] = []) -> UINode {
        UINode(role: .group, id: id, frame: UIFrame(x: x, y: y, width: width, height: height), native: .ios(IOSNativeAttributes()), children: children)
    }

    private static let tree = UITree(platform: .ios, device: "fake-device", roots: [
        node("app", 0, 0, 400, 800, children: [
            node("tab-bar", 0, 750, 400, 50, children: [
                node("tab-search", 130, 750, 130, 50),
            ]),
            node("banner", 0, 700, 400, 100),
        ]),
    ])

    @Test("the chain runs from the root to the deepest hit, through the later overlapping sibling")
    func chainOrder() {
        #expect(Self.tree.hitChain(at: UIPoint(x: 195, y: 775)).compactMap(\.id) == ["app", "banner"])
        #expect(Self.tree.hitChain(at: UIPoint(x: 195, y: 100)).compactMap(\.id) == ["app"])
    }

    @Test("deepestNode is the last node of the chain")
    func deepestIsLast() {
        let tabOnly = UITree(platform: .ios, device: "fake-device", roots: [Self.tree.roots[0].children[0]])
        let point = UIPoint(x: 195, y: 775)

        #expect(tabOnly.hitChain(at: point).compactMap(\.id) == ["tab-bar", "tab-search"])
        #expect(tabOnly.deepestNode(at: point)?.id == "tab-search")
        #expect(Self.tree.deepestNode(at: point)?.id == Self.tree.hitChain(at: point).last?.id)
    }

    @Test("a point outside every root has an empty chain")
    func outside() {
        #expect(Self.tree.hitChain(at: UIPoint(x: 500, y: 10)).isEmpty)
        #expect(Self.tree.deepestNode(at: UIPoint(x: 500, y: 10)) == nil)
    }
}
