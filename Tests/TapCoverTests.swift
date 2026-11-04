import Foundation
import OffsiderCore
import Testing

@Suite("Tap cover judge")
struct TapCoverTests {
    /// Judges a tap on the element whose id, else label, is `targetName`.
    static func judge(_ tree: UITree, target targetName: String, hit: UINode?, candidates: [String]? = nil) throws -> CoverVerdict? {
        let nodes = tree.roots.flatMap { $0.flattened() }
        let target = try #require(nodes.first { $0.id == targetName } ?? nodes.first { $0.label == targetName })
        let point = try #require(target.frame?.center)
        let viewport = try #require(tree.viewport)
        let occluders = nodes.filter { node in
            node.frame?.contains(point) == true && CoverJudge.isPlausibleOccluder(node) && !target.flattened().contains { $0.isSameElement(as: node) }
                && (candidates.map { $0.contains(node.id ?? "") } ?? true)
        }
        return CoverJudge.judge(
            target: target, matched: target, point: point, candidates: occluders, roots: tree.roots, viewport: viewport,
            stack: ScreenStack.build(roots: tree.roots, viewport: viewport), hit: hit
        )
    }

    static func iosFullPage() throws -> UITree {
        try TreeGoldens.tree(of: TreeGoldens.Golden(platform: .ios, screen: "stack-test@full"))
    }

    static func text(_ label: String, _ frame: UIFrame) -> UINode {
        UINode(role: .text, label: label, frame: frame, native: .ios(IOSNativeAttributes(type: "StaticText")))
    }

    @Test("the field miss: a hit-test answering with Buy's text, inside the Products Tab's frame, is Buy covering the tab")
    func coveringButtonsTextInsideTarget() throws {
        let hit = Self.text("Buy", FakeUI.frame(276, 805.3, 30.7, 20.3))

        let verdict = try #require(try Self.judge(try Self.iosFullPage(), target: "stack-test-tab-products", hit: hit))

        #expect(verdict.cover.id == "stack-test-full-buy")
        #expect(verdict.evidence == .hitTest && verdict.isConfident)
    }

    @Test("on the folded Duo turned landscape, a point read answering the screen's content, whose frame misses BackButton's point, proves no cover")
    func hitMissingThePoint() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/duo-cover-landscape-tap-test.json")
        let tree = try UITree(jsonData: Data(contentsOf: url))
        let nodes = tree.roots.flatMap { $0.flattened() }
        let back = try #require(nodes.first { $0.id == "BackButton" })
        let content = try #require(nodes.first { $0.id == "tap-test-screen" && $0.role == .other })
        let point = UIPoint(x: 48, y: 106)
        try #require(content.frame?.contains(point) == false)
        let viewport = try #require(tree.viewport)

        let verdict = CoverJudge.judge(
            target: back, matched: back, point: point, candidates: [], roots: tree.roots, viewport: viewport,
            stack: ScreenStack.build(roots: tree.roots, viewport: viewport), hit: content
        )

        #expect(verdict?.isConfident != true, "\(String(describing: verdict))")
    }

    @Test("a hit on the target's own text is no cover")
    func ownText() throws {
        let hit = Self.text("Buy", FakeUI.frame(276, 805.3, 30.7, 20.3))
        #expect(try Self.judge(try Self.iosFullPage(), target: "stack-test-full-buy", hit: hit) == nil)
    }

    @Test("a hit on a smaller container holding both the target and a candidate tells nothing, so the candidate is only a guess")
    func sharedAncestorHit() throws {
        let row = FakeUI.node(.group, frame: FakeUI.frame(0, 780, 402, 94), children: [
            FakeUI.node(.button, id: "tab", label: "Products Tab", frame: FakeUI.frame(201, 791, 201, 49)),
            FakeUI.node(.button, id: "buy", label: "Buy", frame: FakeUI.frame(197, 793, 189, 45)),
        ])

        let verdict = try #require(try Self.judge(FakeUI.tree([row]), target: "tab", hit: row))

        #expect(verdict.cover.id == "buy")
        #expect(verdict.evidence == .treeOrder && !verdict.isConfident)
    }

    @Test("a hit on the application root or a group spanning the screen, as when the hit-test's retries run out, tells nothing, so Buy over the tab is only a guess")
    func screenRootHitIsNoEvidence() throws {
        let tree = try Self.iosFullPage()
        let screenGroup = tree.roots[0].children[0]

        for hit in [tree.roots[0], screenGroup] {
            let verdict = try #require(try Self.judge(tree, target: "stack-test-tab-products", hit: hit))
            #expect(verdict.cover.id == "stack-test-full-buy")
            #expect(verdict.evidence == .treeOrder && !verdict.isConfident)
        }
    }

    @Test("a root hit over a target with only labelled content, no control, over its point warns of nothing")
    func screenRootHitOverContentIsClear() throws {
        let tree = Self.priceRow(id: "kettle-row")
        #expect(try Self.judge(tree, target: "kettle-row", hit: tree.roots[0]) == nil)
    }

    @Test("a shared ancestor hit over a target beneath a page is the page's control at the point, refused")
    func sharedAncestorOverCoveredScreen() throws {
        let tree = ScreenStackTests.nestedScreens()
        let nodes = tree.roots.flatMap { $0.flattened() }
        let tab = try #require(nodes.first { $0.label == "Home Tab" })
        let viewport = try #require(tree.viewport)
        let point = try #require(tab.frame?.center)

        let verdict = CoverJudge.judge(
            target: tab, matched: tab, point: point, candidates: [], roots: tree.roots, viewport: viewport,
            stack: ScreenStack.build(roots: tree.roots, viewport: viewport), hit: tree.roots[0]
        )

        #expect(verdict?.cover.label == "Buy")
        #expect(verdict?.screen == "Kettle")
        #expect(verdict?.isConfident == true)
    }

    @Test("a label drawn inside a container target is its own content")
    func labelInsideTarget() throws {
        let tree = FakeUI.tree([
            FakeUI.node(.group, id: "card", frame: FakeUI.frame(16, 200, 370, 120)),
            FakeUI.node(.text, id: "card-title", label: "Kettle", frame: FakeUI.frame(32, 250, 200, 20)),
        ])
        #expect(try Self.judge(tree, target: "card", hit: Self.text("Kettle", FakeUI.frame(32, 250, 200, 20))) == nil)
    }

    @Test("a hit answering with the target read again half a point lower is still the target")
    func staleHitFrame() throws {
        let tree = FakeUI.tree([
            FakeUI.node(.button, id: "save", label: "Save", frame: FakeUI.frame(20, 700, 350, 44)),
            FakeUI.node(.other, id: "banner", label: "Saved", frame: FakeUI.frame(0, 690, 402, 30)),
        ])
        let moved = FakeUI.node(.button, id: "save", label: "Save", frame: FakeUI.frame(20, 700.5, 350, 44))

        #expect(try Self.judge(tree, target: "save", hit: moved) == nil)
    }

    /// A product row whose label holds a live price, inside a labelled section that is a cover candidate.
    static func priceRow(id: String?) -> UITree {
        FakeUI.tree([
            FakeUI.node(.other, label: "Products", frame: FakeUI.frame(0, 250, 402, 500)),
            FakeUI.node(.button, id: id, label: "Kettle $129.95", frame: FakeUI.frame(0, 300, 402, 60)),
        ])
    }

    @Test("a hit with the target's role and id is the target, though its price ticked and it moved between the reads")
    func sameIDTickedHit() throws {
        let ticked = FakeUI.node(.button, id: "kettle-row", label: "Kettle $131.22", frame: FakeUI.frame(0, 303, 402, 60))
        #expect(try Self.judge(Self.priceRow(id: "kettle-row"), target: "kettle-row", hit: ticked) == nil)
    }

    @Test("without an id, a hit with the target's role within a point of its frame is the target, though its label ticked")
    func noIDTickedHit() throws {
        let ticked = FakeUI.node(.button, label: "Kettle $131.22", frame: FakeUI.frame(0, 300.5, 402, 60))
        #expect(try Self.judge(Self.priceRow(id: nil), target: "Kettle $129.95", hit: ticked) == nil)
    }

    @Test("without an id, a ticked hit of the target's role that moved further but mostly overlaps it is never a confident cover")
    func noIDMovedHitIsNotConfident() throws {
        let moved = FakeUI.node(.button, label: "Kettle $131.22", frame: FakeUI.frame(0, 306, 402, 60))
        #expect(try Self.judge(Self.priceRow(id: nil), target: "Kettle $129.95", hit: moved)?.isConfident != true)
    }

    @Test("a hit the tree names as another element is that element, though it shares the target's role, id and frame")
    func placedHitSharingID() throws {
        let tree = FakeUI.tree([
            FakeUI.node(.button, id: "cta", label: "Open Full Page", frame: FakeUI.frame(16, 738, 370, 44)),
            FakeUI.node(.button, id: "cta", label: "Open Flags", frame: FakeUI.frame(16, 738, 370, 44)),
        ])
        let flags = tree.roots[0].children[1]

        let verdict = try #require(try Self.judge(tree, target: "Open Full Page", hit: flags))

        #expect(verdict.cover.label == "Open Flags" && verdict.isConfident)
    }

    @Test("Buy's own button over the Products Tab, which it mostly overlaps, stays a confident cover, even read again 2 pt along")
    func overlappingButtonWithOwnID() throws {
        let tree = try Self.iosFullPage()
        let buy = try #require(tree.roots.flatMap { $0.flattened() }.first { $0.id == "stack-test-full-buy" })
        var shifted = buy
        shifted.frame = FakeUI.frame(199, 793, 189, 45)

        for hit in [buy, shifted] {
            let verdict = try #require(try Self.judge(tree, target: "stack-test-tab-products", hit: hit))
            #expect(verdict.cover.id == "stack-test-full-buy" && verdict.isConfident)
        }
    }

    @Test("a page's Back over the menu button below it is the cover")
    func backOverMenuButton() throws {
        let tree = FakeUI.tree([
            FakeUI.node(.button, id: "menu-button", label: "Menu", frame: FakeUI.frame(8, 62, 44, 44)),
            FakeUI.node(.button, id: "product-back", label: "Back", frame: FakeUI.frame(8, 62, 72, 44)),
        ])

        let verdict = try #require(try Self.judge(tree, target: "menu-button", hit: Self.text("Back", FakeUI.frame(24.3, 73.7, 39.3, 20.3))))

        #expect(verdict.cover.id == "product-back")
        #expect(verdict.isConfident)
    }

    /// A size button drawn over the labelled list it sits on, which tree order alone took for a cover.
    static func sizeOverList(platform: DevicePlatform) -> UITree {
        let list = FakeUI.node(.other, id: "popular-list", label: "Popular", frame: FakeUI.frame(0, 300, 402, 400), platform: platform, drawingOrder: 1)
        let size = FakeUI.node(.button, id: "size-btn", label: "S", frame: FakeUI.frame(16, 320, 60, 32), platform: platform, drawingOrder: 2)
        return FakeUI.tree(platform: platform, platform == .ios ? [size, list] : [list, size])
    }

    @Test("a size button drawn over a list stays clear, by hit-test on iOS and by drawing order on Android")
    func sizeOverListIsClear() throws {
        let hit = Self.text("S", FakeUI.frame(36, 326, 20, 20))
        #expect(try Self.judge(Self.sizeOverList(platform: .ios), target: "size-btn", hit: hit) == nil)
        #expect(try Self.judge(Self.sizeOverList(platform: .android), target: "size-btn", hit: nil) == nil)
    }

    @Test("on Android without drawing order, the same list is only a guessed cover")
    func listGuessWithoutDrawingOrder() throws {
        var tree = Self.sizeOverList(platform: .android)
        tree.roots[0].children = tree.roots[0].children.map { node in
            var copy = node
            copy.native = .android(AndroidNativeAttributes(resourceId: node.id))
            return copy
        }
        let verdict = try Self.judge(tree, target: "size-btn", hit: nil)
        #expect(verdict?.cover.id == "popular-list")
        #expect(verdict?.isConfident == false)
    }

    /// An Expo debug build on Android: the dev client's tools button sits in a full-screen host drawn over the app, with a tab bar and maybe a LogBox banner beneath.
    static func toolsHostOverTabs(banner: Bool) -> UITree {
        let fab = FakeUI.node(.group, frame: FakeUI.frame(330, 60, 60, 60), platform: .android, children: [
            FakeUI.node(.image, label: "Tools", frame: FakeUI.frame(347, 77, 26, 26), platform: .android),
        ])
        let host = FakeUI.node(.group, frame: FakeUI.frame(0, 0, 402, 874), platform: .android, drawingOrder: 3, children: [
            FakeUI.node(.group, frame: FakeUI.frame(0, 0, 402, 874), platform: .android, children: [fab]),
        ])
        let tabs = FakeUI.node(.group, id: "tab-bar", frame: FakeUI.frame(0, 800, 402, 74), platform: .android, drawingOrder: 1, children: [
            FakeUI.node(.button, id: "tab-search", label: "Search", frame: FakeUI.frame(134, 800, 134, 49), platform: .android),
        ])
        let toast = FakeUI.node(.button, label: "!, OffsiderFixture error 1", frame: FakeUI.frame(10, 790, 382, 48), platform: .android, drawingOrder: 2)
        return FakeUI.tree(platform: .android, banner ? [host, tabs, toast] : [host, tabs])
    }

    @Test("on Android a full-screen host with nothing at the point, as the Expo dev client's tools button has, takes no tap, so a tab beneath it is clear")
    func toolsHostIsNoCover() throws {
        #expect(try Self.judge(Self.toolsHostOverTabs(banner: false), target: "tab-search", hit: nil) == nil)
    }

    /// `node` with Android's class name for it, and for its children their own.
    static func classed(_ node: UINode, _ className: String, children: [String] = []) -> UINode {
        var copy = node
        if case .android(var attributes) = node.native {
            attributes.className = className
            copy.native = .android(attributes)
        }
        copy.children = zip(node.children, children).map { classed($0, $1) } + node.children.dropFirst(children.count)
        return copy
    }

    @Test("on Android the Expo dev client's Compose host, named by its classes, still takes no tap")
    func composeToolsHostIsNoCover() throws {
        var tree = Self.toolsHostOverTabs(banner: false)
        tree.roots[0].children[0] = Self.classed(tree.roots[0].children[0], "androidx.compose.ui.platform.ComposeView", children: ["android.view.View"])
        #expect(try Self.judge(tree, target: "tab-search", hit: nil) == nil)
    }

    @Test("on Android a React Native view spanning the screen over the tab, which takes the touch in JavaScript, is a guessed cover", arguments: [
        "android.view.ViewGroup", "android.view.View",
    ])
    func reactOverlayIsGuessedCover(className: String) throws {
        var tree = Self.toolsHostOverTabs(banner: false)
        tree.roots[0].children[0] = Self.classed(tree.roots[0].children[0], className, children: [className])

        let verdict = try #require(try Self.judge(tree, target: "tab-search", hit: nil))

        #expect(verdict.cover.frame == FakeUI.frame(0, 0, 402, 874))
        #expect(verdict.evidence == .drawingOrder && !verdict.isConfident)
    }

    /// A React Native stack on Android, flat as the helper sends it: Settings pushed over Home, then an unlabelled full-screen view drawn last.
    static func settingsOverHome(overlayControl: Bool = false, draftSave: Bool = false) -> UITree {
        func button(_ id: String, _ label: String, _ frame: UIFrame) -> UINode {
            FakeUI.node(.button, id: id, label: label, frame: frame, platform: .android)
        }
        let help = button("overlay-help", "Help", FakeUI.frame(150, 700, 100, 50))
        let draft = draftSave ? [button("settings-save-draft", "Save", FakeUI.frame(16, 700, 176, 50))] : []
        let nodes = [
            FakeUI.node(.header, label: "Home", frame: FakeUI.frame(16, 40, 368, 30), platform: .android),
            button("home-filters", "Filters", FakeUI.frame(16, 300, 100, 40)),
            button("home-open", "Open Settings", FakeUI.frame(16, 700, 368, 50)),
            classed(FakeUI.node(.group, id: "settings-page", frame: FakeUI.frame(0, 0, 400, 800), platform: .android), "android.view.ViewGroup"),
            FakeUI.node(.header, label: "Settings", frame: FakeUI.frame(16, 40, 368, 30), platform: .android),
        ] + draft + [
            button("settings-save", "Save", FakeUI.frame(16, 700, 368, 50)),
            classed(FakeUI.node(.group, frame: FakeUI.frame(0, 0, 400, 800), platform: .android, children: overlayControl ? [help] : []), "android.view.ViewGroup"),
        ]
        let drawn = nodes.enumerated().map { order, node in
            var copy = node
            if case .android(var attributes) = node.native {
                attributes.drawingOrder = order + 1
                copy.native = .android(attributes)
            }
            return copy
        }
        return FakeUI.tree(platform: .android, width: 400, height: 800, drawn)
    }

    @Test("on Android an empty React Native view spanning the target's own page takes no tap there, so the target is clear")
    func emptyReactViewOnOwnPage() throws {
        #expect(try Self.judge(Self.settingsOverHome(), target: "settings-save", hit: nil) == nil)
    }

    @Test("on Android a control of that view's own at the point is still a confident cover")
    func controlOnEmptyReactView() throws {
        let verdict = try #require(try Self.judge(Self.settingsOverHome(overlayControl: true), target: "settings-save", hit: nil))
        #expect(verdict.cover.id == "overlay-help")
        #expect(verdict.evidence == .drawingOrder && verdict.isConfident)
        #expect(verdict.screen == "settings-page")
    }

    @Test("on Android a control beneath the page stays refused, naming the page, though an empty React Native view is drawn over both")
    func controlBeneathPageUnderEmptyReactView() throws {
        let verdict = try #require(try Self.judge(Self.settingsOverHome(), target: "home-filters", hit: nil))
        #expect(verdict.cover.id == "settings-page")
        #expect(verdict.isConfident)
    }

    @Test("on Android a LogBox banner beneath that host is still a confident cover by drawing order")
    func bannerBeneathToolsHost() throws {
        let verdict = try #require(try Self.judge(Self.toolsHostOverTabs(banner: true), target: "tab-search", hit: nil))
        #expect(verdict.cover.label == "!, OffsiderFixture error 1")
        #expect(verdict.evidence == .drawingOrder && verdict.isConfident)
    }

    @Test("a page's Back whose wrapper the hit-test finds, on a simulator list ordered by position, is not named as under the button of the screen beneath")
    func wrapperHitNamesNoLowerButton() throws {
        let pid = 42
        let back = FakeUI.node(.button, id: "back", label: "Back", frame: FakeUI.frame(8, 110, 72, 44), pid: pid)
        let wrapper = FakeUI.node(.other, frame: FakeUI.frame(0, 100, 402, 60), pid: pid)
        let front = FakeUI.node(.group, id: "front-list", frame: FakeUI.frame(0, 100, 402, 670), pid: pid, children: [
            wrapper, back, FakeUI.node(.text, label: "Rows", frame: FakeUI.frame(0, 700, 402, 40), pid: pid),
        ])
        let lower = FakeUI.node(.group, id: "lower-list", frame: FakeUI.frame(0, 100, 402, 774), pid: pid, children: [
            FakeUI.node(.button, id: "lower-drawer", label: "Open Drawer", frame: FakeUI.frame(6, 104, 58, 58), pid: pid),
            FakeUI.node(.text, label: "Feed", frame: FakeUI.frame(0, 700, 402, 40), pid: pid),
        ])

        let verdict = try Self.judge(FakeUI.tree([front, lower]), target: "back", hit: wrapper, candidates: [])

        #expect(verdict?.isConfident != true)
    }

    /// A simulator screen with its button and a scrim over it, as it lists them: the scrim first, by position.
    static func scrimOverButton() -> UITree {
        let pid = 42
        return FakeUI.tree([
            FakeUI.node(.group, id: "root", frame: FakeUI.frame(0, 0, 402, 874), pid: pid, children: [
                FakeUI.node(.button, id: "scrim", frame: FakeUI.frame(0, 0, 402, 874), pid: pid),
                FakeUI.node(.text, label: "Title", frame: FakeUI.frame(16, 100, 370, 20), pid: pid),
                FakeUI.node(.button, id: "send", label: "Send", frame: FakeUI.frame(16, 788, 370, 44), pid: pid),
            ]),
        ])
    }

    @Test("a simulator's hit on a scrim under another role is that scrim, a confident cover")
    func scrimAnswerIsConfidentCover() throws {
        let tree = Self.scrimOverButton()
        let hit = FakeUI.node(.other, id: "scrim", frame: FakeUI.frame(0, 0, 402, 874), pid: 42)
        let verdict = try #require(try Self.judge(tree, target: "send", hit: hit, candidates: []))
        #expect(verdict.cover.id == "scrim" && verdict.isConfident && verdict.evidence == .hitTest)
    }

    @Test("a simulator's hit on an unnamed screen-sized group may be a veil, so it is a guess that names it")
    func veilAnswerIsGuess() throws {
        let hit = FakeUI.node(.group, frame: FakeUI.frame(0, 0, 402, 874), pid: 42)
        let tree = FakeUI.tree([
            FakeUI.node(.group, frame: FakeUI.frame(0, 0, 402, 874), pid: 42, children: [
                FakeUI.node(.button, id: "send", label: "Send", frame: FakeUI.frame(16, 788, 370, 44), pid: 42),
            ]),
        ])
        let verdict = try #require(try Self.judge(tree, target: "send", hit: hit, candidates: []))
        #expect(verdict.cover.frame == hit.frame && !verdict.isConfident)
    }

    @Test("a simulator's hit on the application itself says nothing, so the point stays clear")
    func applicationAnswerSaysNothing() throws {
        let tree = Self.scrimOverButton()
        let verdict = try Self.judge(tree, target: "Title", hit: tree.roots[0], candidates: [])
        #expect(verdict == nil)
    }

    @Test("a coveredBy report names role, id, label, frame, screen, evidence and process, and its JSON keeps that order")
    func coverReportJSON() {
        let verdict = CoverVerdict(cover: FakeUI.node(.button, id: "buy", label: "Buy", frame: FakeUI.frame(1, 2, 3, 4)), evidence: .drawingOrder, isConfident: true, screen: "product-page")
        let payload = ErrorPayload(reason: .targetCovered, message: "m", dispatched: .no, coveredBy: CoverReport(verdict))

        #expect(payload.jsonLine().hasSuffix(#""candidates":[],"coveredBy":{"role":"button","id":"buy","label":"Buy","frame":{"x":1,"y":2,"width":3,"height":4},"screen":"product-page","evidence":"drawingOrder","process":null}}"#))
        #expect(!ErrorPayload(reason: .targetCovered, message: "m").jsonLine().contains("coveredBy"))
    }
}
