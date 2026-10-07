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

    @Test("the field miss: a hit-test answering with Buy's text, inside the Home Tab's frame, is Buy covering the tab")
    func coveringButtonsTextInsideTarget() throws {
        let hit = Self.text("Buy", FakeUI.frame(276, 805.3, 30.7, 20.3))

        let verdict = try #require(try Self.judge(try Self.iosFullPage(), target: "stack-test-tab-dashboard", hit: hit))

        #expect(verdict.cover.id == "stack-test-full-buy")
        #expect(verdict.evidence == .hitTest && verdict.isConfident)
    }

    @Test("a hit on the target's own text is no cover")
    func ownText() throws {
        let hit = Self.text("Buy", FakeUI.frame(276, 805.3, 30.7, 20.3))
        #expect(try Self.judge(try Self.iosFullPage(), target: "stack-test-full-buy", hit: hit) == nil)
    }

    @Test("a hit on a smaller container holding both the target and a candidate tells nothing, so the candidate is only a guess")
    func sharedAncestorHit() throws {
        let row = FakeUI.node(.group, frame: FakeUI.frame(0, 780, 402, 94), children: [
            FakeUI.node(.button, id: "tab", label: "Home Tab", frame: FakeUI.frame(201, 791, 201, 49)),
            FakeUI.node(.button, id: "buy", label: "Buy", frame: FakeUI.frame(197, 793, 189, 45)),
        ])

        let verdict = try #require(try Self.judge(FakeUI.tree([row]), target: "tab", hit: row))

        #expect(verdict.cover.id == "buy")
        #expect(verdict.evidence == .treeOrder && !verdict.isConfident)
    }

    @Test("a hit on the application root or a group spanning the screen, as when the hit-test's retries run out, tells nothing and warns of nothing")
    func screenRootHitTellsNothing() throws {
        let tree = try Self.iosFullPage()
        let screenGroup = tree.roots[0].children[0]

        #expect(try Self.judge(tree, target: "stack-test-tab-dashboard", hit: tree.roots[0]) == nil)
        #expect(try Self.judge(tree, target: "stack-test-tab-dashboard", hit: screenGroup) == nil)
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
        #expect(verdict?.screen == "Bitcoin")
        #expect(verdict?.isConfident == true)
    }

    @Test("a label drawn inside a container target is its own content")
    func labelInsideTarget() throws {
        let tree = FakeUI.tree([
            FakeUI.node(.group, id: "card", frame: FakeUI.frame(16, 200, 370, 120)),
            FakeUI.node(.text, id: "card-title", label: "Bitcoin", frame: FakeUI.frame(32, 250, 200, 20)),
        ])
        #expect(try Self.judge(tree, target: "card", hit: Self.text("Bitcoin", FakeUI.frame(32, 250, 200, 20))) == nil)
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

    /// A markets row whose label holds a live price, inside a labelled section that is a cover candidate.
    static func priceRow(id: String?) -> UITree {
        FakeUI.tree([
            FakeUI.node(.other, label: "Markets", frame: FakeUI.frame(0, 250, 402, 500)),
            FakeUI.node(.button, id: id, label: "Bitcoin $64,012.34", frame: FakeUI.frame(0, 300, 402, 60)),
        ])
    }

    @Test("a hit with the target's role and id is the target, though its price ticked and it moved between the reads")
    func sameIDTickedHit() throws {
        let ticked = FakeUI.node(.button, id: "btc-row", label: "Bitcoin $64,013.61", frame: FakeUI.frame(0, 303, 402, 60))
        #expect(try Self.judge(Self.priceRow(id: "btc-row"), target: "btc-row", hit: ticked) == nil)
    }

    @Test("without an id, a hit with the target's role within a point of its frame is the target, though its label ticked")
    func noIDTickedHit() throws {
        let ticked = FakeUI.node(.button, label: "Bitcoin $64,013.61", frame: FakeUI.frame(0, 300.5, 402, 60))
        #expect(try Self.judge(Self.priceRow(id: nil), target: "Bitcoin $64,012.34", hit: ticked) == nil)
    }

    @Test("without an id, a ticked hit of the target's role that moved further but mostly overlaps it is never a confident cover")
    func noIDMovedHitIsNotConfident() throws {
        let moved = FakeUI.node(.button, label: "Bitcoin $64,013.61", frame: FakeUI.frame(0, 306, 402, 60))
        #expect(try Self.judge(Self.priceRow(id: nil), target: "Bitcoin $64,012.34", hit: moved)?.isConfident != true)
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

    @Test("Buy's own button over the Home Tab, which it mostly overlaps, stays a confident cover, even read again 2 pt along")
    func overlappingButtonWithOwnID() throws {
        let tree = try Self.iosFullPage()
        let buy = try #require(tree.roots.flatMap { $0.flattened() }.first { $0.id == "stack-test-full-buy" })
        var shifted = buy
        shifted.frame = FakeUI.frame(199, 793, 189, 45)

        for hit in [buy, shifted] {
            let verdict = try #require(try Self.judge(tree, target: "stack-test-tab-dashboard", hit: hit))
            #expect(verdict.cover.id == "stack-test-full-buy" && verdict.isConfident)
        }
    }

    @Test("a page's Back over the home menu button below it is the cover")
    func backOverHomeMenu() throws {
        let tree = FakeUI.tree([
            FakeUI.node(.button, id: "menu-button", label: "Menu", frame: FakeUI.frame(8, 62, 44, 44)),
            FakeUI.node(.button, id: "asset-back", label: "Back", frame: FakeUI.frame(8, 62, 72, 44)),
        ])

        let verdict = try #require(try Self.judge(tree, target: "menu-button", hit: Self.text("Back", FakeUI.frame(24.3, 73.7, 39.3, 20.3))))

        #expect(verdict.cover.id == "asset-back")
        #expect(verdict.isConfident)
    }

    /// An interval button drawn over the labelled list it sits on, which tree order alone took for a cover.
    static func intervalOverList(platform: DevicePlatform) -> UITree {
        let list = FakeUI.node(.other, id: "popular-list", label: "Trending", frame: FakeUI.frame(0, 300, 402, 400), platform: platform, drawingOrder: 1)
        let interval = FakeUI.node(.button, id: "interval-btn", label: "1D", frame: FakeUI.frame(16, 320, 60, 32), platform: platform, drawingOrder: 2)
        return FakeUI.tree(platform: platform, platform == .ios ? [interval, list] : [list, interval])
    }

    @Test("an interval button drawn over a list stays clear, by hit-test on iOS and by drawing order on Android")
    func intervalOverListIsClear() throws {
        let hit = Self.text("1D", FakeUI.frame(36, 326, 20, 20))
        #expect(try Self.judge(Self.intervalOverList(platform: .ios), target: "interval-btn", hit: hit) == nil)
        #expect(try Self.judge(Self.intervalOverList(platform: .android), target: "interval-btn", hit: nil) == nil)
    }

    @Test("on Android without drawing order, the same list is only a guessed cover")
    func listGuessWithoutDrawingOrder() throws {
        var tree = Self.intervalOverList(platform: .android)
        tree.roots[0].children = tree.roots[0].children.map { node in
            var copy = node
            copy.native = .android(AndroidNativeAttributes(resourceId: node.id))
            return copy
        }
        let verdict = try Self.judge(tree, target: "interval-btn", hit: nil)
        #expect(verdict?.cover.id == "popular-list")
        #expect(verdict?.isConfident == false)
    }

    @Test("a coveredBy report names role, id, label, frame, screen and evidence, and its JSON keeps that order")
    func coverReportJSON() {
        let verdict = CoverVerdict(cover: FakeUI.node(.button, id: "buy", label: "Buy", frame: FakeUI.frame(1, 2, 3, 4)), evidence: .drawingOrder, isConfident: true, screen: "asset-page")
        let payload = ErrorPayload(reason: .targetCovered, message: "m", dispatched: .no, coveredBy: CoverReport(verdict))

        #expect(payload.jsonLine().hasSuffix(#""candidates":[],"coveredBy":{"role":"button","id":"buy","label":"Buy","frame":{"x":1,"y":2,"width":3,"height":4},"screen":"asset-page","evidence":"drawingOrder"}}"#))
        #expect(!ErrorPayload(reason: .targetCovered, message: "m").jsonLine().contains("coveredBy"))
    }
}
