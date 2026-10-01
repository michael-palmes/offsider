import Foundation
import OffsiderCore
import Testing

@Suite("UITree hit testing")
struct UITreeHitTestTests {
    private static func node(_ id: String, _ x: Double, _ y: Double, _ width: Double, _ height: Double, children: [UINode] = []) -> UINode {
        UINode(role: .group, id: id, frame: UIFrame(x: x, y: y, width: width, height: height), native: .android(AndroidNativeAttributes()), children: children)
    }

    private static let tree = UITree(platform: .android, device: "emulator-5556", roots: [
        node("app", 0, 0, 400, 800, children: [
            node("panel", 0, 100, 400, 300, children: [
                node("button", 20, 120, 100, 40),
                node("hidden", 0, 0, 0, 0),
            ]),
            node("underneath", 0, 500, 400, 100),
            node("overlay", 0, 450, 400, 200),
        ]),
    ])

    @Test("the deepest node containing the point wins")
    func deepestWins() {
        #expect(Self.tree.deepestNode(at: UIPoint(x: 50, y: 130))?.id == "button")
        #expect(Self.tree.deepestNode(at: UIPoint(x: 300, y: 130))?.id == "panel")
        #expect(Self.tree.deepestNode(at: UIPoint(x: 300, y: 620))?.id == "overlay")
    }

    @Test("on overlap the later, topmost sibling wins")
    func laterSiblingWins() {
        #expect(Self.tree.deepestNode(at: UIPoint(x: 10, y: 550))?.id == "overlay")
    }

    @Test("a point outside every root is nil, and zero-size nodes are never hit")
    func outside() {
        #expect(Self.tree.deepestNode(at: UIPoint(x: 500, y: 10)) == nil)
        #expect(Self.tree.deepestNode(at: UIPoint(x: 0, y: 0))?.id == "app")
    }
}
