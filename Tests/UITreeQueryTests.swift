import Foundation
import OffsiderCore
import Testing

@Suite("UI Tree Query Tests")
struct UITreeQueryTests {
    private static func node(
        _ role: UIRole,
        id: String? = nil,
        label: String? = nil,
        value: String? = nil,
        frame: UIFrame? = nil,
        actions: [String] = [],
        children: [UINode] = []
    ) -> UINode {
        UINode(role: role, id: id, label: label, value: value, frame: frame, native: .ios(IOSNativeAttributes(customActions: actions)), children: children)
    }

    /// app > scroll > [visible button, group (no frame) > off-screen text]
    private let tree = UITree(
        platform: .ios,
        device: "D",
        screen: UIScreenInfo(width: 400, height: 800),
        roots: [
            node(.application, label: "App", frame: UIFrame(x: 0, y: 0, width: 400, height: 800), children: [
                node(.scrollView, frame: UIFrame(x: 0, y: 0, width: 400, height: 2000), children: [
                    node(.button, label: "Visible", frame: UIFrame(x: 10, y: 10, width: 100, height: 40)),
                    node(.group, children: [
                        node(.text, label: "Below the fold", frame: UIFrame(x: 10, y: 1500, width: 100, height: 20)),
                    ]),
                ]),
            ]),
        ]
    )

    private func labels(_ entries: [UIFlatEntry]) -> [String?] {
        entries.map(\.node.label)
    }

    @Test("an empty filter keeps the tree unchanged and lists every node in pre-order")
    func emptyFilterKeepsEverything() {
        #expect(tree.filtered(UITreeFilter()) == tree)
        #expect(tree.flatEntries(UITreeFilter()).map(\.node.role) == tree.roots[0].flattened().map(\.role))
    }

    @Test("on-screen drops an off-screen child in flat output")
    func onScreenFlatDropsOffScreen() {
        let entries = tree.flatEntries(UITreeFilter(onScreen: true))

        #expect(entries.map(\.node.role) == [.application, .scrollView, .button])
    }

    @Test("on-screen nested output keeps the ancestors of matching nodes")
    func onScreenNestedKeepsAncestors() throws {
        let screen = UITree(platform: .ios, device: "D", screen: UIScreenInfo(width: 400, height: 800), roots: [
            Self.node(.other, children: [
                Self.node(.group, children: [Self.node(.button, label: "Go", frame: UIFrame(x: 0, y: 0, width: 10, height: 10))]),
                Self.node(.text, label: "Away", frame: UIFrame(x: 0, y: 900, width: 10, height: 10)),
            ]),
        ])
        let root = try #require(screen.filtered(UITreeFilter(onScreen: true)).roots.first)

        #expect(root.role == .other)
        #expect(root.children.map(\.role) == [.group])
        #expect(root.children[0].children.map(\.label) == ["Go"])
    }

    @Test("a frame that only touches the screen edge is not on screen")
    func touchingEdgeIsOffScreen() {
        let edge = UITree(platform: .ios, device: "D", screen: UIScreenInfo(width: 400, height: 800), roots: [
            Self.node(.button, frame: UIFrame(x: 0, y: 800, width: 10, height: 10)),
            Self.node(.button, frame: UIFrame(x: 395, y: 795, width: 10, height: 10)),
        ])

        #expect(edge.flatEntries(UITreeFilter(onScreen: true)).count == 1)
    }

    @Test("on-screen keeps everything when neither screen nor frames are known")
    func onScreenWithoutVisibleRect() {
        let unknown = UITree(platform: .ios, device: "D", roots: [Self.node(.button, label: "A")])

        #expect(unknown.visibleRect == nil)
        #expect(unknown.flatEntries(UITreeFilter(onScreen: true)).count == 1)
    }

    @Test("labelled keeps an id-only node and drops an unlabelled or blank group")
    func labelledFilter() {
        let labelled = UITree(platform: .ios, device: "D", roots: [
            Self.node(.group, children: [
                Self.node(.other, id: "only-id"),
                Self.node(.group, label: "  "),
                Self.node(.text, value: "42"),
            ]),
        ])

        #expect(labelled.flatEntries(UITreeFilter(labelled: true)).map(\.node.role) == [.other, .text])
    }

    @Test("actionable keeps controls and iOS elements with custom actions")
    func actionableFilter() {
        let controls = UITree(platform: .ios, device: "D", roots: [
            Self.node(.group, children: [
                Self.node(.button, label: "Tap"),
                Self.node(.text, label: "Plain"),
                Self.node(.other, label: "Swipe me", actions: ["Delete"]),
                Self.node(.switch, label: "Alerts"),
            ]),
        ])

        #expect(labels(controls.flatEntries(UITreeFilter(actionable: true))) == ["Tap", "Swipe me", "Alerts"])
    }

    @Test("filters combine with AND")
    func filtersCombine() {
        let entries = tree.flatEntries(UITreeFilter(onScreen: true, labelled: true, actionable: true))

        #expect(labels(entries) == ["Visible"])
    }

    @Test("flat parent points at the nearest kept ancestor and depth is the full-tree depth")
    func flatParentAndDepth() throws {
        let entries = tree.flatEntries(UITreeFilter(labelled: true))
        let text = try #require(entries.first { $0.node.label == "Below the fold" })

        #expect(labels(entries) == ["App", "Visible", "Below the fold"])
        #expect(entries.map(\.index) == [0, 1, 2])
        #expect(entries[0].parent == nil)
        #expect(entries[1].parent == 0)
        #expect(text.parent == 0)
        #expect(text.depth == 3)
        #expect(entries.allSatisfy { $0.node.children.isEmpty })
    }

    @Test("the visible rect falls back to the application frame without screen info")
    func visibleRectFallback() {
        let app = UIFrame(x: 0, y: 0, width: 300, height: 600)
        let noScreen = UITree(platform: .android, device: "emulator-5554", roots: [Self.node(.application, frame: app)])

        #expect(noScreen.visibleRect == app)
        #expect(tree.visibleRect == UIFrame(x: 0, y: 0, width: 400, height: 800))
    }

    @Test("on-screen uses the selectors' viewport, application and keyboard roots, over the reported screen")
    func onScreenUsesViewport() {
        let tree = UITree(platform: .android, device: "emulator-5554", screen: UIScreenInfo(width: 400, height: 800), roots: [
            Self.node(.application, frame: UIFrame(x: 0, y: 0, width: 400, height: 700), children: [
                Self.node(.button, label: "Inside", frame: UIFrame(x: 10, y: 600, width: 100, height: 40)),
                Self.node(.button, label: "Under the navigation bar", frame: UIFrame(x: 10, y: 720, width: 100, height: 40)),
            ]),
        ])

        #expect(tree.visibleRect == UIFrame(x: 0, y: 0, width: 400, height: 700))
        #expect(labels(tree.flatEntries(UITreeFilter(onScreen: true, labelled: true))) == ["Inside"])
    }

    @Test("a sliver under 1 pt is not on screen, as selectors judge it")
    func sliverIsOffScreen() {
        let tree = UITree(platform: .ios, device: "D", screen: UIScreenInfo(width: 400, height: 800), roots: [
            Self.node(.application, frame: UIFrame(x: 0, y: 0, width: 400, height: 800), children: [
                Self.node(.button, label: "Sliver", frame: UIFrame(x: 10, y: 799.5, width: 100, height: 40)),
            ]),
        ])

        #expect(labels(tree.flatEntries(UITreeFilter(onScreen: true, labelled: true))).isEmpty)
    }
}
