import Foundation
import OffsiderCore
import Testing
@testable import Offsider

/// A simulator lists siblings by position, so a page of another size than the screen it was pushed over says nothing of which is on top; a hit-test settles it.
@Suite("Pages a simulator lists by position")
@MainActor
struct UnorderedPageTests {
    static let ios = DeviceID(rawValue: "fake-device", platform: .ios)
    static let pid = 1000

    static func node(_ role: UIRole, id: String? = nil, label: String? = nil, _ frame: UIFrame, children: [UINode] = []) -> UINode {
        FakeUI.node(role, id: id, label: label, frame: frame, pid: pid, children: children)
    }

    /// A page pushed over a screen whose views React Native lists flat: the page's wrapper comes first, at the corner, and the screen's controls after it, by position.
    static func slidPage() -> UITree {
        let page = node(.group, FakeUI.frame(0, 0, 402, 874), children: [
            node(.group, id: "slide-page-2", FakeUI.frame(0, 0, 402, 874)),
            node(.button, id: "slide-back-2", label: "Back", FakeUI.frame(8, 47, 72, 44)),
            node(.header, id: "slide-title-2", label: "Confirm", FakeUI.frame(88, 59, 214, 20)),
            node(.text, id: "slide-result", label: "Slide Result: None", FakeUI.frame(125, 107, 140, 20)),
            node(.button, id: "slide-confirm-final", label: "Confirm Change", FakeUI.frame(16, 790, 370, 44)),
        ])
        let screen = node(.group, FakeUI.frame(0, 0, 402, 874), children: [
            node(.group, FakeUI.frame(0, 0, 402, 91)),
            page,
            node(.button, id: "back-button", label: "Playground", FakeUI.frame(8, 47, 44, 44)),
            node(.header, id: "screen-title", label: "Mounted Stack", FakeUI.frame(60, 59, 270, 20)),
            node(.text, id: "stack-depth", label: "Stack Depth: 1", FakeUI.frame(16, 135, 370, 20)),
            node(.button, id: "slide-left", label: "Slide Left", FakeUI.frame(16, 244, 175, 44)),
            node(.button, id: "slide-up", label: "Slide Up", FakeUI.frame(211, 244, 175, 44)),
            node(.button, id: "open-full", label: "Open Full Page", FakeUI.frame(16, 600, 370, 44)),
        ] + (1...4).map { line in
            node(.text, id: "stack-line-\(line)", label: "Stack Line \(line)", FakeUI.frame(16, 300 + Double(line) * 50, 370, 20))
        })
        return FakeUI.tree([screen])
    }

    /// A simulator that draws the slid page over everything: a point read finds the page's control there, else its backdrop.
    static func slidPageSimulator() -> HitTestingFakeBackend {
        let tree = slidPage()
        let backend = HitTestingFakeBackend(trees: [tree])
        let page = tree.roots[0].children[0].children[1]
        backend.hits = { point in page.children.dropFirst().first { $0.frame?.contains(point) == true } ?? page.children[0] }
        return backend
    }

    @Test("wait and assert refuse a control under a slid page's empty area, as the tap does, with one hit-test")
    func controlUnderSlidPage() async throws {
        let waiting = Self.slidPageSimulator()
        let route = DeviceRouter.Route(backend: waiting, device: Self.ios)
        let waited = try await Wait.parse(["--id", "slide-up", "--timeout", "0", "--device", Self.ios.rawValue]).evaluate(on: route, logger: OffsiderLogger(), clock: ScriptedClock().poll)
        #expect(!waited.met)
        #expect(waited.reason.hasPrefix(#"beneath "Confirm""#), "\(waited.reason)")
        #expect(waiting.hitTests == 1)

        let asserting = Self.slidPageSimulator()
        let assert = try Assert.parse(["--id", "slide-up", "--device", Self.ios.rawValue])
        let asserted = try await assert.evaluate(on: DeviceRouter.Route(backend: asserting, device: Self.ios), logger: OffsiderLogger())
        #expect(!asserted.met)
        #expect(assert.failureLine(asserted).hasPrefix(#"✗ Assertion failed: --id 'slide-up' is beneath "Confirm""#), "\(assert.failureLine(asserted))")
    }

    @Test("the slid page's own controls stay on screen, and cost no hit-test")
    func pageControlsStayOnScreen() async throws {
        let backend = Self.slidPageSimulator()
        let route = DeviceRouter.Route(backend: backend, device: Self.ios)
        let outcome = try await Assert.parse(["--id", "slide-confirm-final", "--device", Self.ios.rawValue]).evaluate(on: route, logger: OffsiderLogger())
        #expect(outcome.met, "\(outcome.reason)")
        #expect(backend.hitTests == 0)
    }

    @Test("a control drawn over the page, which the hit-test finds, stays on screen")
    func controlOverPageStaysOnScreen() async throws {
        let tree = Self.slidPage()
        let backend = HitTestingFakeBackend(trees: [tree])
        let floating = tree.roots[0].children[0].children.first { $0.id == "slide-up" }
        backend.hits = { _ in floating }
        let outcome = try await Assert.parse(["--id", "slide-up", "--device", Self.ios.rawValue]).evaluate(on: DeviceRouter.Route(backend: backend, device: Self.ios), logger: OffsiderLogger())
        #expect(outcome.met, "\(outcome.reason)")
        #expect(backend.hitTests == 1)
    }

    @Test("describe-ui --summary folds the screen under the slid page beneath it, reading two of its controls the tree cannot order, however many there are")
    func summaryFoldsScreenBeneathSlidPage() async throws {
        let backend = Self.slidPageSimulator()
        let summary = try await OnScreenRuleTests.describe(["--summary"], on: backend, device: Self.ios)
        #expect(!summary.contains("Slide Up"), "\(summary)")
        #expect(!summary.contains("Stack Depth"), "\(summary)")
        #expect(summary.contains(#"button "Confirm Change" id=slide-confirm-final"#), "\(summary)")
        #expect(summary.contains(#"# beneath: "Mounted Stack" (10 elements) under "Confirm""#), "\(summary)")
        // Two pairs of controls overlap, each read at its own point, and the eight beside them are read twice in all.
        #expect(backend.hitTests == 6, "\(backend.hitTests)")
    }

    @Test("with no hit-test to read, the tree's word stands")
    func noHitTestKeepsTreeWord() async throws {
        let backend = FakeDeviceBackend(trees: [Self.slidPage()])
        let outcome = try await Assert.parse(["--id", "slide-up", "--device", Self.ios.rawValue]).evaluate(on: DeviceRouter.Route(backend: backend, device: Self.ios), logger: OffsiderLogger())
        #expect(outcome.met)
    }

    // MARK: A drawer under a page pushed from its row

    /// The drawer, narrower than the screen, is listed before the page pushed from its row; both start at the corner, so position says nothing of which is on top.
    static func drawerUnderRowPage() -> UITree {
        let drawer = node(.group, id: "drawer", FakeUI.frame(0, 0, 280, 874), children: [
            node(.button, id: "drawer-back", label: "Back", FakeUI.frame(16, 63, 55, 44)),
            node(.header, id: "drawer-title", label: "Side Drawer", FakeUI.frame(79, 75, 96, 20)),
            node(.group, FakeUI.frame(16, 115, 248, 280), children: [
                node(.button, id: "row-inbox", label: "Drawer Inbox", FakeUI.frame(16, 115, 248, 64)),
                node(.button, id: "row-reminders", label: "Drawer Reminders", FakeUI.frame(16, 187, 248, 64)),
                node(.button, id: "row-archive", label: "Drawer Archive", FakeUI.frame(16, 259, 248, 64)),
            ]),
        ])
        let page = node(.group, FakeUI.frame(0, 0, 402, 874), children: [
            node(.group, FakeUI.frame(0, 0, 402, 91)),
            node(.group, id: "row-page", FakeUI.frame(0, 0, 402, 874)),
            node(.button, id: "row-page-back", label: "Back", FakeUI.frame(8, 47, 72, 44)),
            node(.header, id: "row-page-title", label: "Reminders", FakeUI.frame(88, 59, 214, 20)),
            node(.button, id: "row-page-reminders", label: "Drawer Reminders", FakeUI.frame(16, 107, 370, 44)),
        ])
        return FakeUI.tree([node(.group, FakeUI.frame(0, 0, 402, 874), children: [drawer, page])])
    }

    static func rowPageSimulator() -> HitTestingFakeBackend {
        let tree = drawerUnderRowPage()
        let backend = HitTestingFakeBackend(trees: [tree, tree])
        let page = tree.roots[0].children[0].children[1]
        backend.hits = { point in page.children.dropFirst(2).first { $0.frame?.contains(point) == true } ?? page.children[1] }
        return backend
    }

    @Test("a label the drawer and the page pushed from its row share taps the page's button")
    func twinLabelTapsPage() async throws {
        let backend = Self.rowPageSimulator()
        try await CoverAndVerifyTests.tap(["--label", "Drawer Reminders", "--fail-if-covered"], on: backend)
        #expect(backend.session.calls == [.perform(.tapAt(x: 201, y: 129))])
    }

    @Test("describe-ui --summary folds the drawer beneath the page pushed from its row")
    func summaryFoldsDrawerBeneathRowPage() async throws {
        let summary = try await OnScreenRuleTests.describe(["--summary"], on: Self.rowPageSimulator(), device: Self.ios)
        #expect(!summary.contains("Drawer Archive"), "\(summary)")
        #expect(summary.contains(#"button "Drawer Reminders" id=row-page-reminders"#), "\(summary)")
        #expect(summary.contains(#"# beneath: "drawer" (6 elements) under "Reminders""#), "\(summary)")
    }

    // MARK: An inactive tab

    /// Two tabs React Native keeps mounted: the inactive one's controls lie flat beside the active tab's taller page, which overlaps nothing labelled there.
    static func inactiveTab() -> UITree {
        let active = node(.group, FakeUI.frame(0, 0, 402, 790), children: [
            node(.header, id: "tab-saved-title", label: "Saved", FakeUI.frame(16, 60, 370, 30)),
            node(.text, id: "saved-row-1", label: "Saved Item 1", FakeUI.frame(16, 120, 370, 30)),
            node(.text, id: "saved-row-9", label: "Saved Item 9", FakeUI.frame(16, 700, 370, 30)),
        ])
        return FakeUI.tree([node(.group, FakeUI.frame(0, 0, 402, 874), children: [
            active,
            node(.button, id: "recent-refresh", label: "Refresh Recent", FakeUI.frame(16, 400, 370, 44)),
            node(.button, id: "tab-recent", label: "Recent Tab", FakeUI.frame(0, 790, 201, 84)),
            node(.button, id: "tab-saved", label: "Saved Tab", FakeUI.frame(201, 790, 201, 84)),
        ])])
    }

    @Test("a lone match on an inactive tab that overlaps nothing labelled is hit-tested, and found beneath the active tab")
    func inactiveTabControl() async throws {
        let tree = Self.inactiveTab()
        let backend = HitTestingFakeBackend(trees: [tree])
        let active = tree.roots[0].children[0].children[0]
        backend.hits = { point in tree.roots[0].children[0].children.dropFirst(2).first { $0.frame?.contains(point) == true } ?? active }
        let outcome = try await Assert.parse(["--id", "recent-refresh", "--device", Self.ios.rawValue]).evaluate(on: DeviceRouter.Route(backend: backend, device: Self.ios), logger: OffsiderLogger())
        #expect(!outcome.met)
        #expect(outcome.reason.hasPrefix(#"beneath "Saved""#), "\(outcome.reason)")

        let tab = try await Assert.parse(["--id", "tab-saved", "--device", Self.ios.rawValue]).evaluate(on: DeviceRouter.Route(backend: backend, device: Self.ios), logger: OffsiderLogger())
        #expect(tab.met, "\(tab.reason)")
    }
}

/// A simulator's point read of a view the app hides finds its text, never the view around it, so a filled-in heading has no id.
@Suite("Hidden elements a simulator reads with no id")
struct HiddenWithoutIDTests {
    static func filled(_ hidden: [UINode], platform: DevicePlatform = .ios) -> UITree {
        var tree = FakeUI.tree(platform: platform, hidden + [
            FakeUI.node(.button, id: "drawer-back", label: "Back", frame: FakeUI.frame(16, 63, 55, 44), platform: platform),
        ])
        tree.filledFromGaps = hidden.count
        return tree
    }

    static let heading = FakeUI.node(.text, label: "Reset the drawer?", frame: FakeUI.frame(16, 115, 248, 20))

    @Test("an id that matches nothing names the one hidden element read with no id, and the label that finds it")
    func missNamesHiddenTextWithoutID() throws {
        let tree = Self.filled([Self.heading, FakeUI.node(.button, id: "confirm-reset", label: "Reset Drawer", frame: FakeUI.frame(16, 151, 248, 44))])
        let miss = try #require(SelectorQuery.explain(.id("confirm-title"))(tree))
        #expect(miss.summary == #"the app hides text "Reset the drawer?", whose id a simulator cannot read; if that is it, use --label 'Reset the drawer?'"#)
    }

    @Test("with several such elements the miss counts them and names the first")
    func missCountsSeveral() throws {
        let tree = Self.filled([Self.heading, FakeUI.node(.text, label: "This cannot be undone", frame: FakeUI.frame(16, 140, 248, 20))])
        let miss = try #require(SelectorQuery.explain(.id("confirm-title"))(tree))
        #expect(miss.summary == #"2 elements hidden from accessibility have no id a simulator can read, such as text "Reset the drawer?"; use --label"#)
    }

    @Test("an unfilled read, a label selector and Android keep the usual miss")
    func usualMissElsewhere() {
        var plain = Self.filled([Self.heading])
        plain.filledFromGaps = nil
        #expect(SelectorQuery.explain(.id("confirm-title"))(plain) == nil)
        #expect(SelectorQuery.explain(.id("confirm-title"))(Self.filled([FakeUI.node(.text, label: "Reset the drawer?", frame: FakeUI.frame(16, 115, 248, 20), platform: .android)], platform: .android)) == nil)
        #expect(SelectorQuery.explain(.label("Nowhere To Be Seen"))(Self.filled([Self.heading]))?.summary.contains("hidden") != true)
    }
}

/// A pager whose page a touch reaches only through the pager around it, as a story that takes every touch does.
@Suite("Covered by its own page")
@MainActor
struct OwnPageRefusalTests {
    static func pager() -> (tree: UITree, pager: UINode) {
        let page = UnorderedPageTests.node(.group, id: "story-page-1", FakeUI.frame(0, 100, 402, 674), children: [
            UnorderedPageTests.node(.text, id: "story-text", label: "Welcome to the story", FakeUI.frame(16, 300, 370, 30)),
        ])
        let pager = UnorderedPageTests.node(.button, id: "story", label: "Story", FakeUI.frame(0, 0, 402, 874), children: [page])
        return (FakeUI.tree([pager]), pager)
    }

    @Test("a tap refused as covered by the page that holds it keeps refusing, and the hint gives the tap on that page")
    func refusalGivesThePageTap() async throws {
        let (tree, pager) = Self.pager()
        let backend = HitTestingFakeBackend(trees: [tree])
        backend.hits = { _ in pager }
        do {
            try await CoverAndVerifyTests.tap(["--id", "story-page-1", "--fail-if-covered"], on: backend)
            Issue.record("the tap went through")
        } catch let error as CLIError {
            #expect(backend.session.calls.isEmpty)
            #expect(error.reason == .targetCovered)
            #expect(error.errorDescription?.contains("covered by the page that holds it") == true, "\(error.errorDescription ?? "")")
            #expect(error.errorDescription?.hasSuffix("Nothing was sent. To tap the page instead: `offsider tap -x 201 -y 437 --device fake-device`.") == true, "\(error.errorDescription ?? "")")
            #expect(error.hint == "offsider tap -x 201 -y 437 --device fake-device", "\(error.hint ?? "")")
        }
    }
}
