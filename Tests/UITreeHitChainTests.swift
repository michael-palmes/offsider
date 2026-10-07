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

    /// The Android full page golden: the page and its content are drawn after the mounted stack's tabs, but listed among them.
    static func fullPage() throws -> UITree {
        try TreeGoldens.tree(of: TreeGoldens.Golden(platform: .android, screen: "stack-test@full"))
    }

    static func node(_ id: String, in tree: UITree) throws -> UINode {
        try #require(tree.roots.flatMap { $0.flattened() }.first { $0.id == id })
    }

    @Test("on Android drawing order picks the sibling on top, whatever the listing order")
    func drawingOrderPicksTop() throws {
        let tree = try Self.fullPage()
        let dashboard = try Self.node("stack-test-tab-dashboard", in: tree)
        let home = try Self.node("stack-test-tab-home", in: tree)

        #expect(tree.deepestNode(at: try #require(dashboard.frame?.center))?.id == "stack-test-full-buy")
        #expect(tree.deepestNode(at: try #require(home.frame?.center))?.id == "stack-test-full-page-1")
    }

    @Test("without drawing order on every sibling, the last listed is on top")
    func treeOrderWithoutDrawingOrder() {
        let tree = UITree(platform: .android, device: "emulator-5554", roots: [
            FakeUI.node(.application, frame: FakeUI.frame(0, 0, 400, 800), platform: .android, children: [
                FakeUI.node(.button, id: "drawn-last", frame: FakeUI.frame(0, 0, 100, 100), platform: .android, drawingOrder: 9),
                FakeUI.node(.button, id: "listed-last", frame: FakeUI.frame(0, 0, 100, 100), platform: .android),
            ]),
        ])
        #expect(tree.deepestNode(at: UIPoint(x: 50, y: 50))?.id == "listed-last")
    }

    @Test("roots are hit by window layer, the highest first")
    func windowLayers() {
        func root(_ id: String, layer: Int) -> UINode {
            UINode(role: .application, id: id, frame: FakeUI.frame(0, 0, 400, 800), native: .android(AndroidNativeAttributes(windowLayer: layer)))
        }
        let tree = UITree(platform: .android, device: "emulator-5554", roots: [root("front", layer: 2), root("back", layer: 1)])
        #expect(tree.deepestNode(at: UIPoint(x: 10, y: 10))?.id == "front")
    }

    @Test("a node Android hides from the user takes no touch, unless its whole window is hidden behind a keyboard")
    func hiddenNodes() {
        func node(_ id: String, visible: Bool, children: [UINode] = []) -> UINode {
            UINode(role: .group, id: id, frame: FakeUI.frame(0, 0, 400, 800), native: .android(AndroidNativeAttributes(visibleToUser: visible)), children: children)
        }
        let partly = UITree(platform: .android, device: "emulator-5554", roots: [node("app", visible: true, children: [node("shown", visible: true), node("hidden", visible: false)])])
        #expect(partly.deepestNode(at: UIPoint(x: 10, y: 10))?.id == "shown")

        let whole = UITree(platform: .android, device: "emulator-5554", roots: [node("app", visible: false, children: [node("field", visible: false)])])
        #expect(whole.deepestNode(at: UIPoint(x: 10, y: 10))?.id == "field")
    }

    @Test("zOrder says Buy is drawn over the Home Tab by drawing order, and falls back to tree order on iOS")
    func zOrder() throws {
        let tree = try Self.fullPage()
        let buy = try Self.node("stack-test-full-buy", in: tree)
        let tab = try Self.node("stack-test-tab-dashboard", in: tree)
        let android = try #require(UITree.zOrder(of: buy, over: tab, in: tree.roots))
        #expect(android.isAbove && android.byDrawingOrder)
        #expect(UITree.zOrder(of: tab, over: buy, in: tree.roots)?.isAbove == false)

        let ios = Self.tree.roots
        let banner = ios[0].children[1], tab2 = ios[0].children[0].children[0]
        let guess = try #require(UITree.zOrder(of: banner, over: tab2, in: ios))
        #expect(guess.isAbove && !guess.byDrawingOrder)
        #expect(UITree.zOrder(of: tab2, over: ios[0].children[0], in: ios).map { $0.isAbove && $0.byDrawingOrder } == true)
    }
}

