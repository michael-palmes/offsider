import Foundation
import OffsiderCore
import Testing
@testable import Offsider

/// One rule for what is on screen: a touch at an element's point reaches it. `wait`, `assert`, `tap` and `describe-ui --on-screen` all judge by it.
@Suite("On-screen rule")
@MainActor
struct OnScreenRuleTests {
    static let ios = DeviceID(rawValue: "fake-device", platform: .ios)
    static let android = DeviceID(rawValue: "fake-device", platform: .android)

    static let chipFrame = FakeUI.frame(16, 180, 160, 44)
    static let inboxFrame = FakeUI.frame(16, 170, 248, 64)

    /// A page drawn over a side drawer that stays mounted at its open position while closed; the drawer is listed after the page, as React Native lists a drawer it draws beneath.
    static func closedDrawer(platform: DevicePlatform) -> UITree {
        let page = FakeUI.node(.group, id: "page", frame: FakeUI.frame(0, 0, 402, 874), platform: platform, drawingOrder: 2, children: [
            FakeUI.node(.button, id: "open-menu", label: "Open Menu", frame: FakeUI.frame(16, 110, 370, 44), platform: platform, drawingOrder: 1),
            FakeUI.node(.button, id: "filter-chip", label: "Filter Chip", frame: chipFrame, platform: platform, drawingOrder: 2),
        ])
        let drawer = FakeUI.node(.group, id: "drawer", frame: FakeUI.frame(0, 0, 280, 874), platform: platform, drawingOrder: 1, children: [
            FakeUI.node(.button, id: "menu-inbox", label: "Menu Inbox", frame: inboxFrame, platform: platform, drawingOrder: 1),
        ])
        return FakeUI.tree(platform: platform, [page, drawer])
    }

    /// A simulator whose hit-test answers with what the page draws at a point: the chip over the drawer's row.
    static func drawerSimulator() -> HitTestingFakeBackend {
        let backend = HitTestingFakeBackend(trees: [closedDrawer(platform: .ios)])
        let page = closedDrawer(platform: .ios).roots[0].children[0]
        backend.hits = { point in page.children.first { $0.frame?.contains(point) == true } ?? page }
        return backend
    }

    static func backends() -> [(FakeDeviceBackend, DeviceID)] {
        [(drawerSimulator(), ios), (FakeDeviceBackend(trees: [closedDrawer(platform: .android)]), android)]
    }

    @Test("wait and assert do not count a closed drawer's row the page is drawn over, by the simulator's hit-test and by Android's drawing order")
    func closedDrawerRowIsNotOnScreen() async throws {
        for (backend, device) in Self.backends() {
            let route = DeviceRouter.Route(backend: backend, device: device)
            let wait = try Wait.parse(["--id", "menu-inbox", "--timeout", "0", "--device", device.rawValue])
            let waited = try await wait.evaluate(on: route, logger: OffsiderLogger(), clock: ScriptedClock().poll)
            #expect(!waited.met)
            #expect(waited.reason == #"under button "Filter Chip" (16, 180) 160x44, so a tap would not reach it"#, "\(device.platform)")

            let assert = try Assert.parse(["--id", "menu-inbox", "--device", device.rawValue])
            let asserted = try await assert.evaluate(on: route, logger: OffsiderLogger())
            #expect(assert.failureLine(asserted) == #"✗ Assertion failed: --id 'menu-inbox' is under button "Filter Chip" (16, 180) 160x44, so a tap would not reach it."#)

            let chip = try await Assert.parse(["--id", "filter-chip", "--device", device.rawValue]).evaluate(on: route, logger: OffsiderLogger())
            #expect(chip.met)
        }
    }

    @Test("--allow-offscreen still finds a covered row, since it asks only whether the app holds it")
    func allowOffscreenFindsCoveredRow() async throws {
        let route = DeviceRouter.Route(backend: FakeDeviceBackend(trees: [Self.closedDrawer(platform: .android)]), device: Self.android)
        let outcome = try await Assert.parse(["--id", "menu-inbox", "--allow-offscreen", "--device", Self.android.rawValue]).evaluate(on: route, logger: OffsiderLogger())
        #expect(outcome.met)
    }

    @Test("describe-ui --summary leaves the closed drawer's rows out and counts them, on both platforms")
    func summaryFoldsCoveredRows() async throws {
        for (backend, device) in Self.backends() {
            let summary = try await Self.describe(["--summary"], on: backend, device: device)
            #expect(!summary.contains("Menu Inbox"), "\(summary)")
            #expect(summary.contains(#"button "Filter Chip" id=filter-chip"#))
            #expect(summary.hasSuffix("# covered: 2 elements under others: id=drawer, id=menu-inbox\n"), "\(summary)")
        }
    }

    @Test("describe-ui --on-screen JSON leaves the covered row out, and plain JSON keeps every node")
    func onScreenJSONLeavesCoveredOut() async throws {
        let onScreen = try await Self.describe(["--on-screen", "--flat"], on: FakeDeviceBackend(trees: [Self.closedDrawer(platform: .android)]), device: Self.android)
        #expect(!onScreen.contains("menu-inbox") && onScreen.contains("filter-chip"))
        let all = try await Self.describe([], on: FakeDeviceBackend(trees: [Self.closedDrawer(platform: .android)]), device: Self.android)
        #expect(all.contains("menu-inbox"))
    }

    @Test("an iOS simulator hit-tests only elements something may draw over, all at once, so a screen with no overlap reads no point")
    func hitTestsOnlyContestedPoints() async throws {
        let plain = HitTestingFakeBackend(trees: [FakeUI.tree([
            FakeUI.node(.button, id: "save", label: "Save", frame: FakeUI.frame(16, 600, 370, 44)),
            FakeUI.node(.text, id: "total", label: "Total", frame: FakeUI.frame(16, 120, 370, 20)),
        ])])
        _ = try await Self.describe(["--summary"], on: plain, device: Self.ios)
        #expect(plain.hitTests == 0)

        let drawer = Self.drawerSimulator()
        _ = try await Self.describe(["--summary"], on: drawer, device: Self.ios)
        #expect(drawer.hitPoints.contains(UIPoint(x: 140, y: 202)) && drawer.hitPoints.contains(UIPoint(x: 96, y: 202)))
        #expect(!drawer.hitPoints.contains(UIPoint(x: 201, y: 132)))
    }

    // MARK: Tab bar

    static let tabBar = FakeUI.node(.group, id: "tab-bar", frame: FakeUI.frame(0, 790, 402, 84), children: [
        FakeUI.node(.button, id: "tab-home", label: "Home Tab", frame: FakeUI.frame(0, 790, 201, 49)),
        FakeUI.node(.button, id: "tab-saved", label: "Saved Tab", frame: FakeUI.frame(201, 790, 201, 49)),
    ])

    /// A list running under a bottom tab bar: row 12 shows its top 15 pt above the bar, row 13 lies wholly under it.
    static func listUnderTabBar(platform: DevicePlatform = .ios) -> UITree {
        let rows = (11...13).map { row in
            FakeUI.node(.button, id: "row-\(row)", label: "Row \(row)", frame: FakeUI.frame(0, 719 + Double(row - 11) * 56, 402, 56))
        }
        return FakeUI.tree([FakeUI.node(.group, id: "list", frame: FakeUI.frame(0, 159, 402, 715), children: rows), tabBar])
    }

    /// A simulator whose hit-test answers with the tab bar's buttons, else its padding, over the rows.
    static func tabBarSimulator() -> HitTestingFakeBackend {
        let tree = listUnderTabBar()
        let backend = HitTestingFakeBackend(trees: [tree, tree])
        backend.hits = { point in
            if let tab = tabBar.children.first(where: { $0.frame?.contains(point) == true }) { return tab }
            if tabBar.frame?.contains(point) == true { return tabBar }
            return tree.roots[0].children[0].children.first { $0.frame?.contains(point) == true }
        }
        return backend
    }

    @Test("tap on a row half under the tab bar taps the part that shows, after a hit-test there finds the row")
    func tapsVisiblePartAboveTabBar() async throws {
        let backend = Self.tabBarSimulator()

        try await Self.tap(["--id", "row-12"], on: backend)

        #expect(backend.session.calls == [.perform(.tapAt(x: 201, y: 782.5))])
        #expect(backend.hitPoints.map(\.y) == [803, 782.5])
    }

    @Test("a closed drawer's row is refused, not tapped beside the page's control that covers its centre, when the hit-test there answers with the page")
    func coveredRowBesideCoverStaysRefused() async throws {
        let backend = Self.drawerSimulator()

        let error = await #expect(throws: CLIError.self) { try await Self.tap(["--id", "menu-inbox"], on: backend) }

        #expect(error?.coveredBy?.id == "filter-chip")
        #expect(backend.session.calls.isEmpty)
    }

    @Test("on Android, whose tree leaves an opaque page's background out, a covered row is refused rather than tapped beside its cover")
    func androidNeverMovesCoveredTap() async throws {
        let backend = FakeDeviceBackend(platform: .android, trees: [Self.closedDrawer(platform: .android)])

        let error = await #expect(throws: CLIError.self) {
            try await TypeIntoTests.quiet {
                try await Tap.parse(["--id", "menu-inbox", "--no-settle", "--device", Self.android.rawValue])
                    .execute(on: DeviceRouter.Route(backend: backend, device: Self.android), progress: nil, logger: OffsiderLogger())
            }
        }

        #expect(error?.coveredBy?.id == "filter-chip")
        #expect(backend.session.calls.isEmpty)
    }

    @Test("tap on a row wholly under the tab bar's padding is refused as covered by the tab bar, not tapped silently")
    func refusesRowUnderTabBarPadding() async throws {
        let backend = Self.tabBarSimulator()

        let error = await #expect(throws: CLIError.self) { try await Self.tap(["--id", "row-13"], on: backend) }

        #expect(error?.reason == .targetCovered)
        #expect(error?.coveredBy?.id == "tab-bar")
        #expect(backend.session.calls.isEmpty)
    }

    @Test("a physical iPhone's scroll bar, a labelled element of no known type, is never named as the cover of a row beneath the tab bar")
    func deviceScrollBarIsNoCover() throws {
        let indicator = FakeUI.node(.other, label: "Horizontal scroll bar, 1 page", frame: FakeUI.frame(25, 841, 352, 30))
        let list = FakeUI.node(.scrollView, frame: FakeUI.frame(0, 159, 402, 715), children: [
            FakeUI.node(.button, id: "row-13", label: "Row 13", frame: FakeUI.frame(0, 831, 402, 56)), indicator,
        ])
        let tree = FakeUI.tree([list, Self.tabBar])

        let resolution = try AccessibilityTargetResolver.resolveTap(roots: tree.roots, query: .id("row-13"))

        #expect(!resolution.coverCandidates.contains { $0.label == indicator.label })
        #expect(resolution.coverCandidates.map(\.id).contains("tab-bar"))
    }

    // MARK: Footer, pages and keypads

    @Test("a footer bar pinned over a scroll view's button refuses the tap when the hit-test answers with the bar")
    func footerBarCoversButton() async throws {
        let footer = FakeUI.node(.group, frame: FakeUI.frame(0, 700, 402, 72), children: [
            FakeUI.node(.button, id: "footer-action", label: "Footer Action", frame: FakeUI.frame(266, 714, 120, 44)),
        ])
        let tree = FakeUI.tree([
            FakeUI.node(.group, id: "scroll", frame: FakeUI.frame(0, 159, 402, 715), children: [
                FakeUI.node(.button, id: "buy", label: "Buy", frame: FakeUI.frame(16, 690, 370, 44)),
            ]),
            footer,
        ])
        let backend = HitTestingFakeBackend(trees: [tree, tree])
        backend.hits = { point in footer.frame?.contains(point) == true ? footer : tree.roots[0].children[0].children[0] }

        try await Self.tap(["--id", "buy"], on: backend)

        #expect(backend.session.calls == [.perform(.tapAt(x: 201, y: 695))])
    }

    /// A pushed page whose Back sits where the page beneath has its own, nested as a physical iPhone lists them; no hit-test there.
    static func backOverBack() -> UITree {
        func page(_ id: String, title: String) -> UINode {
            FakeUI.node(.other, id: id, frame: FakeUI.frame(0, 0, 402, 874), children: [
                FakeUI.node(.button, label: "Back", frame: FakeUI.frame(5, 61, 40, 40)),
                FakeUI.node(.header, label: title, frame: FakeUI.frame(60, 70, 282, 22)),
                FakeUI.node(.button, id: "\(id)-action", label: "Continue", frame: FakeUI.frame(16, 600, 370, 44)),
            ])
        }
        return FakeUI.tree([page("details", title: "Details"), page("notes", title: "Notes")])
    }

    @Test("tap --label Back on the front page warns of nothing from the identical Back on the page beneath")
    func backOverBackIsClear() async throws {
        let backend = FakeDeviceBackend(trees: [Self.backOverBack(), Self.backOverBack()])

        let stderr = try await Self.tap(["--label", "Back", "--fail-if-covered"], on: backend)

        #expect(backend.session.calls == [.perform(.tapAt(x: 25, y: 81))])
        #expect(!stderr.contains("covered"))
    }

    @Test("a key of a keypad the app draws over its amount field is not covered by the field, on a physical iPhone's tree order")
    func appKeypadKeyIsClear() async throws {
        let keys = FakeUI.node(.group, frame: FakeUI.frame(0, 600, 402, 274), children: (1...3).map { key in
            FakeUI.node(.keyboard, label: "\(key)", frame: FakeUI.frame(8 + Double(key - 1) * 129, 608, 129, 56))
        })
        let amount = FakeUI.node(.button, id: "amount", label: "Amount, 0, Points", frame: FakeUI.frame(16, 300, 370, 560))
        let backend = FakeDeviceBackend(trees: [FakeUI.tree([keys, amount]), FakeUI.tree([keys, amount])])

        let stderr = try await Self.tap(["--label", "2", "--element-type", "keyboard", "--fail-if-covered"], on: backend)

        #expect(backend.session.calls == [.perform(.tapAt(x: 201.5, y: 636))])
        #expect(!stderr.contains("covered"))
    }

    // MARK: Android

    @Test("in Compose a clickable row holding a button never covers it, though the row's text overlaps the button and is drawn over it")
    func composeRowHoldsItsButton() throws {
        let row = UINode(role: .button, label: "Fee, 0.5", frame: FakeUI.frame(16, 307, 411, 72), native: .android(AndroidNativeAttributes(className: "android.view.View", drawingOrder: 1)), children: [
            UINode(role: .button, id: "fee-info", frame: FakeUI.frame(363, 319, 48, 48), native: .android(AndroidNativeAttributes(className: "android.view.View", resourceId: "fee-info", drawingOrder: 1))),
            UINode(role: .text, label: "Fee", frame: FakeUI.frame(32, 319, 360, 48), native: .android(AndroidNativeAttributes(className: "android.view.View", drawingOrder: 2))),
        ])
        let host = UINode(role: .group, frame: FakeUI.frame(0, 0, 427, 900), native: .android(AndroidNativeAttributes(className: "androidx.compose.ui.platform.ComposeView", drawingOrder: 1)), children: [row])
        let tree = FakeUI.tree(platform: .android, width: 427, height: 900, [host])

        #expect(try TapCoverTests.judge(tree, target: "fee-info", hit: nil) == nil)
    }

    @Test("on Android a title under the next page's title, in its place or wider, is covered by drawing order, and the top title is not")
    func androidTitleUnderNextTitle() throws {
        func page(_ id: String, title: String, frame: UIFrame, order: Int) -> UINode {
            FakeUI.node(.group, id: id, frame: FakeUI.frame(0, 0, 411, 923), platform: .android, drawingOrder: order, children: [
                FakeUI.node(.group, id: "\(id)-title", label: title, frame: frame, platform: .android, drawingOrder: 1),
            ])
        }
        let tree = FakeUI.tree(platform: .android, width: 411, height: 923, [
            page("keypad", title: "Keypad", frame: FakeUI.frame(60, 64, 291, 23), order: 1),
            page("details", title: "Details", frame: FakeUI.frame(88, 64, 235, 23), order: 2),
            page("notes", title: "Notes", frame: FakeUI.frame(88, 64, 235, 23), order: 3),
        ])

        #expect(try TapCoverTests.judge(tree, target: "details-title", hit: nil)?.cover.normalizedID == "notes-title")
        #expect(try TapCoverTests.judge(tree, target: "keypad-title", hit: nil)?.cover.normalizedID == "notes-title")
        #expect(try TapCoverTests.judge(tree, target: "notes-title", hit: nil) == nil)
    }

    @Test("assert does not count an element on a screen beneath a pushed page, so it proves which screen is in front")
    func beneathScreenIsNotOnScreen() async throws {
        let tree = ScreenStackTests.nestedScreens()
        let backend = FakeDeviceBackend(trees: [tree])
        let tab = try #require(tree.roots.flatMap { $0.flattened() }.first { $0.label == "Home Tab" })
        let route = DeviceRouter.Route(backend: backend, device: Self.ios)

        let outcome = try await Assert.parse(["--label", tab.label!, "--device", Self.ios.rawValue]).evaluate(on: route, logger: OffsiderLogger())

        #expect(!outcome.met)
        #expect(outcome.reason.hasPrefix("beneath \"Kettle\""), "\(outcome.reason)")
    }

    /// Two pages as an iOS simulator lists a React Native stack: each page's group childless and screen-sized, its elements flat beside it, both titles in one place.
    static func flatStack() -> UITree {
        FakeUI.tree([
            FakeUI.node(.group, id: "details-page", frame: FakeUI.frame(0, 0, 402, 874)),
            FakeUI.node(.group, id: "notes-page", frame: FakeUI.frame(0, 0, 402, 874)),
            FakeUI.node(.header, id: "details-title", label: "Details", frame: FakeUI.frame(88, 74, 226, 20)),
            FakeUI.node(.header, id: "notes-title", label: "Notes", frame: FakeUI.frame(88, 74, 226, 20)),
            FakeUI.node(.button, id: "open-notes", label: "Open Notes", frame: FakeUI.frame(16, 122, 370, 44)),
        ])
    }

    @Test("a hit-test answering with the next page's title text, in this title's place, covers this title; its own text does not")
    func otherTitleTextCovers() throws {
        let tree = Self.flatStack()
        let notesText = FakeUI.node(.text, label: "Notes", frame: FakeUI.frame(88, 74, 226, 20))

        let verdict = try TapCoverTests.judge(tree, target: "details-title", hit: notesText)

        #expect(verdict?.cover.normalizedID == "notes-title")
        #expect(verdict?.isConfident == true)
        #expect(try TapCoverTests.judge(tree, target: "notes-title", hit: notesText) == nil)
    }

    @Test("a hit-test answering with a longer label that holds this title's, in its place, is no sure cover")
    func mergedLabelInPlaceIsNoSureCover() throws {
        let tree = Self.flatStack()
        let merged = FakeUI.node(.text, label: "Details, 3 notes", frame: FakeUI.frame(88, 74, 226, 20))

        let verdict = try TapCoverTests.judge(tree, target: "details-title", hit: merged)

        #expect(verdict?.isConfident != true)
    }

    @Test("a hit-test answering with another page's screen-sized group covers what lies under it, the other page's group included")
    func pageGroupHitCovers() throws {
        let tree = Self.flatStack()
        let notesPage = tree.roots[0].children[1]

        #expect(try TapCoverTests.judge(tree, target: "open-notes", hit: notesPage)?.cover.normalizedID == "notes-page")
        #expect(try TapCoverTests.judge(tree, target: "details-page", hit: notesPage)?.cover.normalizedID == "notes-page")
        #expect(try TapCoverTests.judge(tree, target: "notes-page", hit: notesPage) == nil)
    }

    // MARK: Keyboard

    @Test("context.keyboard is false while the keyboard's frame lies below the screen, and true once it meets it")
    func keyboardOffScreenIsNotShown() {
        func tree(keyboardY: Double) -> UITree {
            FakeUI.tree([FakeUI.node(.keyboard, id: "UIKeyboardLayoutStar Preview", frame: FakeUI.frame(0, keyboardY, 402, 300))])
        }
        #expect(!tree(keyboardY: 900).context.keyboard)
        #expect(tree(keyboardY: 574).context.keyboard)
    }

    // MARK: Helpers

    static func describe(_ arguments: [String], on backend: FakeDeviceBackend, device: DeviceID) async throws -> String {
        defer { DeviceActivityLedger.current.reset() }
        return try await DescribeUI.parse(arguments + ["--device", device.rawValue]).describe(on: DeviceRouter.Route(backend: backend, device: device))
    }

    // MARK: Groups

    /// A gallery group with a strip inside it, under a full page Android lists with no container, so no page is found; a gap in the page's rows leaves the group's own point under nothing labelled.
    static func groupUnderRows(showingTitle: Bool = false) -> UITree {
        func android(_ role: UIRole, id: String? = nil, label: String? = nil, _ frame: UIFrame, order: Int, children: [UINode] = []) -> UINode {
            FakeUI.node(role, id: id, label: label, frame: frame, platform: .android, drawingOrder: order, children: children)
        }
        let panel = android(.group, id: "panel", FakeUI.frame(0, 60, 400, 400), order: 1, children: [
            android(.text, id: "panel-title", label: "Panel Title", FakeUI.frame(16, 70, 368, 30), order: 1),
            android(.text, id: "panel-body", label: "Panel Body", FakeUI.frame(16, 170, 368, 30), order: 2),
        ])
        let gallery = android(.group, id: "gallery", FakeUI.frame(0, 60, 400, 540), order: 1, children: [panel])
        let rows = [60, 110, 160, 210, 510].filter { !showingTitle || $0 != 60 }.map { y in
            android(.button, id: "row-\(y)", label: "Row \(y)", FakeUI.frame(0, Double(y), 400, 50), order: y)
        }
        let list = android(.scrollView, FakeUI.frame(0, 60, 400, 500), order: 2, children: rows)
        return FakeUI.tree(platform: .android, width: 400, height: 800, [gallery, list])
    }

    /// The same screens as Android often lists them, flat: the group, then what lies inside it, then the page's list; only the group's last line shows below the list.
    static func flatGroupUnderList(list: UINode? = nil) -> UITree {
        func android(_ role: UIRole, id: String? = nil, label: String? = nil, _ frame: UIFrame, order: Int, children: [UINode] = []) -> UINode {
            FakeUI.node(role, id: id, label: label, frame: frame, platform: .android, drawingOrder: order, children: children)
        }
        let cover = list ?? android(.scrollView, id: "page-list", FakeUI.frame(0, 40, 400, 500), order: 5, children: [
            android(.button, id: "row-1", label: "Row One", FakeUI.frame(0, 40, 400, 50), order: 1),
        ])
        return FakeUI.tree(platform: .android, width: 400, height: 800, [
            android(.group, id: "gallery", FakeUI.frame(0, 60, 400, 600), order: 1),
            android(.group, id: "panel", FakeUI.frame(0, 60, 400, 500), order: 2),
            android(.text, id: "panel-title", label: "Panel Title", FakeUI.frame(16, 70, 368, 30), order: 3),
            android(.text, id: "position", label: "Panel 1 of 3", FakeUI.frame(16, 620, 368, 30), order: 4),
            cover,
        ])
    }

    @Test("a group Android lists flat, under a page's list that reaches past it, is out of reach though one line of it shows")
    func flatGroupUnderPageList() async throws {
        #expect(await Self.placement(of: "gallery", in: Self.flatGroupUnderList()) != .front)
        #expect(await Self.placement(of: "position", in: Self.flatGroupUnderList()) == .front)
    }

    @Test("an empty view over that group proves nothing, so it stays in front")
    func flatGroupUnderEmptyView() async throws {
        let empty = FakeUI.node(.group, frame: FakeUI.frame(0, 40, 400, 700), platform: .android, drawingOrder: 5)
        #expect(await Self.placement(of: "gallery", in: Self.flatGroupUnderList(list: empty)) == .front)
    }

    @Test("a list inside the group's own frame is its own, so the group stays in front")
    func flatGroupWithOwnList() async throws {
        let own = FakeUI.node(.scrollView, frame: FakeUI.frame(0, 100, 400, 500), platform: .android, drawingOrder: 5, children: [
            FakeUI.node(.button, label: "Own Row", frame: FakeUI.frame(0, 100, 400, 50), platform: .android, drawingOrder: 1),
        ])
        #expect(await Self.placement(of: "gallery", in: Self.flatGroupUnderList(list: own)) == .front)
    }

    @Test("a button under a list drawn over it stays a guess, not a sure cover, as a group's rule is only for groups")
    func buttonUnderListStaysGuess() throws {
        let tree = FakeUI.tree(platform: .android, width: 400, height: 800, [
            FakeUI.node(.button, id: "act", label: "Act", frame: FakeUI.frame(16, 300, 368, 44), platform: .android, drawingOrder: 1),
            FakeUI.node(.scrollView, frame: FakeUI.frame(0, 40, 400, 500), platform: .android, drawingOrder: 2, children: [
                FakeUI.node(.button, label: "Row One", frame: FakeUI.frame(0, 40, 400, 50), platform: .android, drawingOrder: 1),
            ]),
        ])
        let verdict = try #require(try TapCoverTests.judge(tree, target: "act", hit: nil))
        #expect(!verdict.isConfident)
    }

    static func placement(of id: String, in tree: UITree) async -> Verifier.Placement {
        let judged = await Verifier.judged(tree, id: id, backend: FakeDeviceBackend(trees: [tree]), device: android)
        return Verifier.placement(of: id, in: judged)
    }

    @Test("a group whose every element is under another page is out of reach, though its own point finds nothing labelled")
    func groupFollowsWhatItHolds() async throws {
        #expect(await Self.placement(of: "gallery", in: Self.groupUnderRows()) != .front)
    }

    @Test("a group with one element showing stays in front")
    func groupWithElementShowing() async throws {
        #expect(await Self.placement(of: "gallery", in: Self.groupUnderRows(showingTitle: true)) == .front)
    }

    @Test("a group holding nothing labelled is judged by its own point alone")
    func emptyGroupKeepsItsOwnJudgement() async throws {
        let empty = FakeUI.node(.group, id: "empty", frame: FakeUI.frame(0, 60, 400, 500), platform: .android, drawingOrder: 1, children: [
            FakeUI.node(.group, frame: FakeUI.frame(0, 60, 400, 400), platform: .android, drawingOrder: 1),
        ])
        #expect(await Self.placement(of: "empty", in: FakeUI.tree(platform: .android, width: 400, height: 800, [empty])) == .front)
    }

    @Test("a tap on a group under another screen's list refuses, as it counts as covered")
    func tapOnCoveredGroup() throws {
        let verdict = try #require(try TapCoverTests.judge(Self.flatGroupUnderList(), target: "gallery", hit: nil))
        #expect(verdict.cover.id == "page-list" && verdict.isConfident && verdict.evidence == .drawingOrder)
    }

    // MARK: A list over a longer list

    static func listsOverLists() -> (tree: UITree, card: UINode, row: UINode) {
        let pid = 42
        let row = FakeUI.node(.button, id: "row-3", label: "Row Three", frame: FakeUI.frame(12, 250, 378, 48), pid: pid)
        let scroll = { (frame: UIFrame, children: [UINode]) in FakeUI.node(.scrollView, frame: frame, pid: pid, children: children) }
        let front = FakeUI.node(.group, id: "front-list", frame: FakeUI.frame(0, 100, 402, 670), pid: pid, children: [scroll(FakeUI.frame(0, 100, 402, 670), [row])])
        let card = FakeUI.node(.other, label: "Saved Card", frame: FakeUI.frame(12, 230, 378, 68), pid: pid)
        let lower = FakeUI.node(.group, id: "lower-list", frame: FakeUI.frame(0, 100, 402, 774), pid: pid, children: [scroll(FakeUI.frame(0, 100, 402, 774), [card])])
        return (FakeUI.tree([front, lower]), card, row)
    }

    @Test("a page's row over a longer list beneath taps with --fail-if-covered, when a read at the card there finds the row too")
    func cardBeneathIsNoGuess() async throws {
        let (tree, _, row) = Self.listsOverLists()
        let backend = HitTestingFakeBackend(trees: [tree, tree])
        backend.hits = { _ in row }

        try await Self.tap(["--id", "row-3", "--fail-if-covered"], on: backend)

        #expect(backend.session.calls.count == 1)
    }

    @Test("a card that shows at its own point stays a guessed cover, so --fail-if-covered refuses and names it")
    func cardThatShowsStaysGuessed() async throws {
        let (tree, card, row) = Self.listsOverLists()
        let cardCentre = try #require(card.frame?.center)
        let backend = HitTestingFakeBackend(trees: [tree, tree])
        backend.hits = { point in point == cardCentre ? card : row }

        let error = await #expect(throws: CLIError.self) { try await Self.tap(["--id", "row-3", "--fail-if-covered"], on: backend) }

        #expect(error?.reason == .targetCovered)
        #expect(error?.errorDescription?.contains("Saved Card") == true)
        #expect(backend.session.calls.isEmpty)
    }

    @Test("a simulator's hit at a group's point on another list's row puts the group beneath it, though the row lies inside its frame")
    func groupUnderOtherList() async throws {
        var (tree, _, row) = Self.listsOverLists()
        // A line of the group shows below the row, so only the point at its middle can tell.
        let shown = FakeUI.node(.text, id: "lower-end", label: "Lower End", frame: FakeUI.frame(0, 820, 402, 40), pid: 42)
        let middle = FakeUI.node(.button, id: "row-9", label: "Row Nine", frame: FakeUI.frame(12, 463, 378, 48), pid: 42)
        tree.roots[0].children[1].children[0].children.append(shown)
        tree.roots[0].children[0].children[0].children.append(middle)
        let backend = HitTestingFakeBackend(trees: [tree])
        backend.hits = { point in point.y > 800 ? shown : point.y > 400 ? middle : row }
        let judged = await Verifier.judged(tree, id: "lower-list", backend: backend, device: Self.ios)
        #expect(Verifier.placement(of: "lower-list", in: judged) != .front)
        #expect(Verifier.placement(of: "lower-end", in: judged) == .front)
    }

    @Test("a simulator's hit at a group's point on its own list's row leaves it in front")
    func groupOverItsOwnList() async throws {
        let (tree, card, _) = Self.listsOverLists()
        let backend = HitTestingFakeBackend(trees: [tree])
        backend.hits = { _ in card }
        let judged = await Verifier.judged(tree, id: "lower-list", backend: backend, device: Self.ios)
        #expect(Verifier.placement(of: "lower-list", in: judged) == .front)
    }

    /// A simulator's button with nothing listed over it, where a view the tree leaves unnamed answers the hit-test.
    static func unnamedScrimSimulator() -> HitTestingFakeBackend {
        let tree = FakeUI.tree([FakeUI.node(.button, id: "send", label: "Send", frame: FakeUI.frame(16, 788, 370, 44), pid: 42)])
        let backend = HitTestingFakeBackend(trees: [tree, tree])
        backend.hits = { _ in FakeUI.node(.group, frame: FakeUI.frame(0, 0, 402, 874), pid: 42) }
        return backend
    }

    @Test("--fail-if-covered reads the point though nothing listed overlaps it, so an unnamed veil refuses and nothing is sent")
    func failIfCoveredReadsThePoint() async throws {
        let backend = Self.unnamedScrimSimulator()
        let error = await #expect(throws: CLIError.self) { try await Self.tap(["--id", "send", "--fail-if-covered"], on: backend) }
        #expect(error?.reason == .targetCovered)
        #expect(backend.hitTests > 0)
        #expect(backend.session.calls.isEmpty)
    }

    @Test("--fail-if-covered refuses when the point cannot be read, and nothing is sent")
    func failIfCoveredRefusesAnUnreadPoint() async throws {
        let backend = Self.unnamedScrimSimulator()
        backend.hits = { _ in nil }
        let error = await #expect(throws: CLIError.self) { try await Self.tap(["--id", "send", "--fail-if-covered"], on: backend) }
        #expect(error?.reason == .targetCovered)
        #expect(backend.session.calls.isEmpty)
    }

    /// A simulator's group of `count` labelled rows, with a page's rows answering every hit-test.
    static func groupOfRows(_ count: Int) -> HitTestingFakeBackend {
        let rows = (0..<count).map { FakeUI.node(.text, id: "held-\($0)", label: "Held \($0)", frame: FakeUI.frame(0, Double(100 + $0 % 30 * 20), 402, 20), pid: 42) }
        let tree = FakeUI.tree([FakeUI.node(.group, id: "held", frame: FakeUI.frame(0, 100, 402, 700), pid: 42, children: rows)])
        let backend = HitTestingFakeBackend(trees: [tree])
        backend.hits = { _ in FakeUI.node(.button, id: "over", label: "Over", frame: FakeUI.frame(0, 100, 402, 700), pid: 42) }
        return backend
    }

    @Test("wait on a group reads no point for what it holds on a simulator, so it stays as fast as it was")
    func waitOnGroupReadsNoPoints() async throws {
        let backend = Self.groupOfRows(10)
        let route = DeviceRouter.Route(backend: backend, device: Self.ios)
        _ = try await Wait.parse(["--id", "held", "--timeout", "0", "--device", Self.ios.rawValue]).evaluate(on: route, logger: OffsiderLogger(), clock: ScriptedClock().poll)
        #expect(backend.hitTests == 0)
    }

    @Test("--verify-id's read of a group stays within the limit of reads, and one too big to finish reads only its own point", arguments: [10, 300])
    func verifyGroupStaysWithinLimit(count: Int) async throws {
        let backend = Self.groupOfRows(count)
        let tree = try await backend.accessibilityTree(for: Self.ios)
        _ = await Verifier.judged(tree, id: "held", backend: backend, device: Self.ios)
        #expect(backend.hitTests <= FrontJudge.hitLimit)
        if count > FrontJudge.hitLimit { #expect(backend.hitTests == 1) } else { #expect(backend.hitTests > 1) }
    }

    @Test("a plain tap reads no point where nothing listed overlaps it, so it stays as fast as it was")
    func plainTapReadsNoPoint() async throws {
        let backend = Self.unnamedScrimSimulator()
        try await Self.tap(["--id", "send"], on: backend)
        #expect(backend.hitTests == 0)
        #expect(backend.session.calls.count == 1)
    }

    /// Runs `tap` on an iOS fake as an agent and returns what it wrote to stderr.
    @discardableResult
    static func tap(_ arguments: [String], on backend: FakeDeviceBackend) async throws -> String {
        let capture = ConsoleCapture()
        try await Console.$current.withValue(capture.console(out: .agent, err: .agent)) {
            try await TypeIntoTests.quiet {
                try await Tap.parse(arguments + ["--no-settle", "--device", ios.rawValue])
                    .execute(on: DeviceRouter.Route(backend: backend, device: ios), progress: nil, logger: OffsiderLogger())
            }
        }
        return capture.err
    }
}
