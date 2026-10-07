import Foundation
import OffsiderCore
import Testing
@testable import OffsiderAndroid

/// A Galaxy Z Fold's dump of a full page drawn over the mounted stack, as One UI's accessibility service lists it.
@Suite("Galaxy Z Fold stacked page")
struct GalaxyFoldStackTests {
    static func tree() throws -> UITree {
        let dump = try JSONDecoder().decode(HelperDump.self, from: Data(GalaxyFoldStackFixtures.fullPageDump.utf8))
        let scale = try #require(AndroidDisplayGeometry(display: dump.display)?.scale)
        var tree = UITree(platform: .android, device: "R5CT00000000", roots: HelperTreeMapping.roots(from: dump, scale: scale, pid: 1).roots)
        tree.windows = HelperTreeMapping.windows(from: dump, scale: scale)
        return tree
    }

    static func node(_ id: String, in tree: UITree) throws -> UINode {
        try #require(tree.roots.flatMap { $0.flattened() }.first { $0.id == id })
    }

    @Test("One UI's dump carries drawing order, so the page's Buy is drawn over the Products Tab listed after it")
    func buyDrawnOverTab() throws {
        let tree = try Self.tree()
        let tab = try Self.node("stack-test-tab-products", in: tree)
        let buy = try Self.node("stack-test-full-buy", in: tree)

        #expect(UITree.zOrder(of: buy, over: tab, in: tree.roots).map { $0.isAbove && $0.byDrawingOrder } == true)
        #expect(tree.deepestNode(at: try #require(tab.frame?.center))?.id == "stack-test-full-buy")
    }

    @Test("the mounted stack lies beneath the full page, and a tap on its Products Tab is refused, naming Buy")
    func tabUnderPageRefused() throws {
        let tree = try Self.tree()
        let viewport = try #require(tree.viewport)
        let stack = ScreenStack.build(roots: tree.roots, viewport: viewport)
        #expect(stack.beneath.map(\.name) == ["Mounted Stack"])
        #expect(stack.beneath.map(\.under) == ["stack-test-full-page-1"])

        let tab = try Self.node("stack-test-tab-products", in: tree)
        let buy = try Self.node("stack-test-full-buy", in: tree)
        let verdict = CoverJudge.judge(
            target: tab, matched: tab, point: try #require(tab.frame?.center), candidates: [buy],
            roots: tree.roots, viewport: viewport, stack: stack, hit: nil
        )
        #expect(verdict?.cover.id == "stack-test-full-buy")
        #expect(verdict?.evidence == .drawingOrder)
        #expect(verdict?.isConfident == true)
    }
}
