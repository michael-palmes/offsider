import Foundation
import OffsiderCore
import Testing

@Suite("Screen stack")
struct ScreenStackTests {
    static let viewport = FakeUI.frame(0, 0, 402, 874)

    static func stack(_ tree: UITree) -> ScreenStack {
        ScreenStack.build(roots: tree.roots, viewport: tree.viewport)
    }

    static func golden(_ platform: DevicePlatform, _ screen: String) throws -> UITree {
        try TreeGoldens.tree(of: TreeGoldens.Golden(platform: platform, screen: screen))
    }

    static func node(_ id: String, in tree: UITree) throws -> UINode {
        try #require(tree.roots.flatMap { $0.flattened() }.first { $0.id == id })
    }

    @Test("no golden but the full pages has a screen beneath another", arguments: TreeGoldens.all().filter { !$0.screen.hasPrefix("stack-test@") })
    func goldensHaveNoCoveredScreen(golden: TreeGoldens.Golden) throws {
        let tree = try TreeGoldens.tree(of: golden)
        #expect(Self.stack(tree).beneath.isEmpty)
    }

    @Test("on Android a full page drawn over the mounted stack covers it, named by its title, under the page's id")
    func androidFullPage() throws {
        let tree = try Self.golden(.android, "stack-test@full")
        let stack = Self.stack(tree)

        #expect(stack.beneath.map(\.name) == ["Mounted Stack"])
        #expect(stack.beneath.map(\.under) == ["stack-test-full-page-1"])
        #expect(stack.isBeneath(try Self.node("stack-test-tab-dashboard", in: tree), in: tree.roots))
        #expect(stack.isBeneath(try Self.node("BackButton", in: tree), in: tree.roots))
        #expect(!stack.isBeneath(try Self.node("stack-test-full-buy", in: tree), in: tree.roots))
        let buy = try #require(ScreenStack.index(of: try Self.node("stack-test-full-buy", in: tree), in: tree.roots))
        #expect(stack.screenName(of: buy) == "stack-test-full-page-1")
    }

    @Test("Android siblings without drawing order give no stack")
    func androidWithoutDrawingOrder() throws {
        func strip(_ node: UINode) -> UINode {
            var copy = node
            if case .android(var attributes) = copy.native {
                attributes.drawingOrder = nil
                copy.native = .android(attributes)
            }
            copy.children = node.children.map(strip)
            return copy
        }
        var tree = try Self.golden(.android, "stack-test@full")
        tree.roots = tree.roots.map(strip)
        #expect(Self.stack(tree) == .empty)
    }

    /// iOS lists a stack's screens as siblings, the pushed one last.
    static func nestedScreens(lowerX: Double = 0, upperY: Double = 0) -> UITree {
        let lower = FakeUI.node(.group, frame: FakeUI.frame(lowerX, 0, 402, 874), children: [
            FakeUI.node(.header, label: "Assets", frame: FakeUI.frame(lowerX + 60, 60, 282, 20)),
            FakeUI.node(.button, id: "asset-row", label: "Bitcoin", frame: FakeUI.frame(lowerX + 16, 120, 370, 60)),
            FakeUI.node(.button, label: "Dashboard Tab", frame: FakeUI.frame(lowerX, 790, 201, 49)),
        ])
        let upper = FakeUI.node(.group, frame: FakeUI.frame(0, upperY, 402, 874 - upperY), children: [
            FakeUI.node(.header, label: "Bitcoin", frame: FakeUI.frame(60, upperY + 60, 282, 20)),
            FakeUI.node(.text, label: "Price", frame: FakeUI.frame(16, 300, 370, 20)),
            FakeUI.node(.button, label: "Buy", frame: FakeUI.frame(16, 790, 370, 49)),
        ])
        return FakeUI.tree([lower, upper])
    }

    @Test("on iOS a later screen sibling covers the earlier one, both named by their headers")
    func iosPushedScreen() throws {
        let tree = Self.nestedScreens()
        let stack = Self.stack(tree)

        #expect(stack.beneath.map(\.name) == ["Assets"])
        #expect(stack.beneath.map(\.under) == ["Bitcoin"])
        #expect(stack.beneath.map(\.elements) == [4])
        let tab = try #require(tree.roots[0].flattened().first { $0.label == "Dashboard Tab" })
        #expect(stack.isBeneath(tab, in: tree.roots))
    }

    @Test("a screen pushed partly off to the left is covered by the page enclosing what is left of it")
    func offsetScreen() {
        #expect(Self.stack(Self.nestedScreens(lowerX: -120)).beneath.map(\.name) == ["Assets"])
    }

    @Test("an earlier screen showing past the page's edge stays uncovered")
    func notEnclosed() {
        #expect(Self.stack(Self.nestedScreens(upperY: 100)).beneath.isEmpty)
    }

    /// An Android base screen with an overlay host drawn over it; `content` goes on the host.
    static func overlayHost(_ content: [UINode]) -> UITree {
        let base = [
            FakeUI.node(.group, label: "Dashboard", frame: FakeUI.frame(60, 60, 282, 20), platform: .android, drawingOrder: 1),
            FakeUI.node(.button, id: "tab", label: "Dashboard Tab", frame: FakeUI.frame(0, 790, 201, 49), platform: .android, drawingOrder: 2),
        ]
        let host = FakeUI.node(.group, id: "host", frame: FakeUI.frame(0, 0, 402, 874), platform: .android, drawingOrder: 3)
        return FakeUI.tree(platform: .android, base + [host] + content)
    }

    @Test("a host showing only a banner at its top is not a page")
    func topBannerIsNotPage() {
        let banner = FakeUI.node(.text, label: "You are offline", frame: FakeUI.frame(0, 50, 402, 40), platform: .android, drawingOrder: 4)
        #expect(Self.stack(Self.overlayHost([banner])).beneath.isEmpty)
    }

    @Test("a host holding a screen-sized control, a scrim, is not a page")
    func scrimHostIsNotPage() {
        let scrim = FakeUI.node(.button, label: "Dismiss", frame: FakeUI.frame(0, 0, 402, 874), platform: .android, drawingOrder: 4)
        let title = FakeUI.node(.text, label: "Filters", frame: FakeUI.frame(16, 100, 370, 20), platform: .android, drawingOrder: 5)
        let apply = FakeUI.node(.button, label: "Apply", frame: FakeUI.frame(16, 800, 370, 44), platform: .android, drawingOrder: 6)
        #expect(Self.stack(Self.overlayHost([scrim, title, apply])).beneath.isEmpty)
    }

    @Test("a host whose content runs from its top past its middle is a page over the base")
    func fullHostIsPage() {
        let title = FakeUI.node(.text, label: "Settings", frame: FakeUI.frame(16, 60, 370, 20), platform: .android, drawingOrder: 4)
        let row = FakeUI.node(.button, label: "Sign out", frame: FakeUI.frame(16, 700, 370, 44), platform: .android, drawingOrder: 5)
        let stack = Self.stack(Self.overlayHost([title, row]))
        #expect(stack.beneath.map(\.name) == ["Dashboard"])
        #expect(stack.beneath.map(\.under) == ["host"])
    }

    @Test("a tree without a screen has no stack")
    func noViewport() {
        #expect(ScreenStack.build(roots: Self.nestedScreens().roots, viewport: nil) == .empty)
    }
}
