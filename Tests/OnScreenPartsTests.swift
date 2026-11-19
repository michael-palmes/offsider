import Foundation
import OffsiderCore
import Testing
@testable import Offsider

/// A presence check counts an element when part of it shows beside a plain label drawn on it; a tap on it keeps its own verdict, and so does anything under a control, a list or a page.
extension OnScreenRuleTests {
    static func android(_ role: UIRole, id: String? = nil, label: String? = nil, _ frame: UIFrame, order: Int, children: [UINode] = []) -> UINode {
        FakeUI.node(role, id: id, label: label, frame: frame, platform: .android, drawingOrder: order, children: children)
    }

    static let card = FakeUI.frame(214, 300, 180, 72)

    /// A card holding its title in a corner, and a badge drawn over its centre from beside it, as Android lists a label an app positions over a card.
    static func badgedCard(badge: UIFrame = FakeUI.frame(291, 327, 27, 18), role: UIRole = .text, extra: [UINode] = []) -> UITree {
        FakeUI.tree(platform: .android, width: 400, height: 800, [
            android(.group, id: "card", card, order: 1, children: [android(.text, label: "Card Title", FakeUI.frame(222, 308, 70, 18), order: 1)]),
            android(role, id: "badge", label: "New", badge, order: 2),
        ] + extra)
    }

    static func waited(_ id: String, in tree: UITree) async throws -> (met: Bool, reason: String?, backend: FakeDeviceBackend) {
        let backend = FakeDeviceBackend(platform: .android, trees: [tree])
        let route = DeviceRouter.Route(backend: backend, device: android)
        let outcome = try await Wait.parse(["--id", id, "--timeout", "0", "--device", android.rawValue]).evaluate(on: route, logger: OffsiderLogger(), clock: ScriptedClock().poll)
        return (outcome.met, outcome.reason, backend)
    }

    @Test("on Android a card with a label drawn over its centre from beside it is on screen for wait and assert, as most of it shows")
    func androidCardShowsBesideBadge() async throws {
        let waited = try await Self.waited("card", in: Self.badgedCard())
        #expect(waited.met, "\(waited.reason ?? "")")

        let route = DeviceRouter.Route(backend: FakeDeviceBackend(platform: .android, trees: [Self.badgedCard()]), device: Self.android)
        #expect(try await Assert.parse(["--id", "card", "--device", Self.android.rawValue]).evaluate(on: route, logger: OffsiderLogger()).met)
        #expect(await Self.placement(of: "card", in: Self.badgedCard()) == .front)
    }

    @Test("that presence check reads the tree once and nothing else, so it costs no device read")
    func androidPartsNeedNoDeviceRead() async throws {
        let waited = try await Self.waited("card", in: Self.badgedCard())
        #expect(waited.backend.treeReads == 1)
        #expect(waited.backend.screenshotReads == 0)
    }

    @Test("a tap on that card is still refused, naming the badge, with and without --fail-if-covered", arguments: [[], ["--fail-if-covered"]])
    func androidTapOnBadgedCardStaysRefused(flags: [String]) async throws {
        let backend = FakeDeviceBackend(platform: .android, trees: [Self.badgedCard()])
        let error = await #expect(throws: CLIError.self) {
            try await TypeIntoTests.quiet {
                try await Tap.parse(["--id", "card", "--no-settle", "--device", Self.android.rawValue] + flags)
                    .execute(on: DeviceRouter.Route(backend: backend, device: Self.android), progress: nil, logger: OffsiderLogger())
            }
        }
        #expect(error?.reason == .targetCovered)
        #expect(error?.coveredBy?.id == "badge" && error?.coveredBy?.evidence == .drawingOrder)
        #expect(error?.errorDescription?.contains("Android draws it on top there") == true)
        #expect(backend.session.calls.isEmpty)
    }

    @Test("the shared reading still says a touch at that card's point misses it, so nothing that acts on the point takes it for clear")
    func androidPartShowingStillMissesAtItsPoint() async throws {
        var tree = Self.badgedCard()
        await FrontJudge.read(matching: [.id("card")], elementType: nil, in: &tree, backend: FakeDeviceBackend(platform: .android, trees: [tree]), device: Self.android)
        let front = try #require(tree.front)
        let index = try #require(ScreenStack.index(of: tree.roots[0].children[0], in: tree.roots))
        #expect(front.covered[index] == nil)
        #expect(front.judged[index]?.verdict?.cover.id == "badge")
        #expect(front.misses(at: index))
    }

    @Test("a card under a label that reaches past it is still not on screen, as the label may be another screen's")
    func androidCardUnderWiderLabelStaysOut() async throws {
        let waited = try await Self.waited("card", in: Self.badgedCard(badge: FakeUI.frame(150, 327, 200, 18)))
        #expect(!waited.met)
        #expect(waited.reason == #"under text "New" (150, 327) 200x18, so a tap would not reach it"#)
    }

    @Test("a card with a control drawn over its centre is still not on screen, as a control may be a dialog's or a page's")
    func androidCardUnderControlStaysOut() async throws {
        let waited = try await Self.waited("card", in: Self.badgedCard(role: .button))
        #expect(!waited.met)
        #expect(waited.reason == #"under button "New" (291, 327) 27x18, so a tap would not reach it"#)
    }

    @Test("a card with a control from outside it drawn over a corner is still not on screen, though its centre is under a plain label")
    func androidCardUnderOutsideControlStaysOut() async throws {
        let close = Self.android(.button, id: "close", label: "Close", FakeUI.frame(370, 296, 30, 30), order: 3)
        #expect(!(try await Self.waited("card", in: Self.badgedCard(extra: [close])).met))
    }

    @Test("a search field from outside the card drawn over a corner counts as a control too, so the card is still not on screen")
    func androidCardUnderOutsideSearchFieldStaysOut() async throws {
        let search = Self.android(.searchField, id: "search", label: "Search", FakeUI.frame(300, 290, 100, 30), order: 3)
        #expect(!(try await Self.waited("card", in: Self.badgedCard(extra: [search])).met))
    }

    @Test("an empty view from outside the card, over the one part its label leaves, that looks just like a wrapper the card holds is not taken for the card's own")
    func androidCardPartUnderLookAlikeWrapper() async throws {
        let strip = FakeUI.frame(214, 300, 180, 18)
        var tree = Self.badgedCard(badge: FakeUI.frame(214, 318, 180, 54), extra: [Self.android(.group, strip, order: 3)])
        #expect(try await Self.waited("card", in: tree).met == false)
        tree.roots[0].children[0].children.append(Self.android(.group, strip, order: 2))
        #expect(try await Self.waited("card", in: tree).met == false)
    }

    @Test("a control drawn beneath the card, or beside it, does not stop the card showing")
    func androidCardOverLowerControlShows() async throws {
        let under = Self.android(.button, id: "row", label: "Row", FakeUI.frame(200, 290, 200, 100), order: 0)
        let beside = Self.android(.button, id: "next", label: "Next", FakeUI.frame(214, 372, 180, 44), order: 3)
        #expect(try await Self.waited("card", in: Self.badgedCard(extra: [under, beside])).met)
    }

    @Test("a card whose parts beside its label lie under other labels is still not on screen")
    func androidCardPartsUnderOtherCovers() async throws {
        let banner = { (id: String, y: Double) in Self.android(.text, id: id, label: id, FakeUI.frame(200, y, 200, 30), order: 3) }
        let tree = Self.badgedCard(badge: FakeUI.frame(214, 327, 180, 18), extra: [banner("above", 298), banner("below", 344)])
        let waited = try await Self.waited("card", in: tree)
        #expect(!waited.met, "the parts above and below the badge are each under a banner")
    }

    @Test("a card under a label with an empty view drawn over the rest of it is still not on screen, as that view may be a veil")
    func androidCardPartUnderEmptyViewStaysOut() async throws {
        let veil = Self.android(.group, FakeUI.frame(0, 0, 400, 800), order: 3)
        #expect(!(try await Self.waited("card", in: Self.badgedCard(extra: [veil])).met))
    }

    @Test("a screen-sized group under a dialog Android lists flat, its text over the group's centre, is still not on screen")
    func androidScreenUnderFlatDialogStaysOut() async throws {
        let tree = FakeUI.tree(platform: .android, width: 400, height: 800, [
            Self.android(.group, id: "home-screen", FakeUI.frame(0, 0, 400, 800), order: 1, children: [Self.android(.text, label: "Home", FakeUI.frame(16, 60, 100, 30), order: 1)]),
            Self.android(.text, id: "dialog-text", label: "Delete this item?", FakeUI.frame(60, 380, 280, 40), order: 2),
            Self.android(.button, id: "dialog-close", label: "Close", FakeUI.frame(60, 440, 280, 48), order: 3),
        ])
        let waited = try await Self.waited("home-screen", in: tree)
        #expect(!waited.met)
        #expect(waited.reason == #"under text "Delete this item?" (60, 380) 280x40, so a tap would not reach it"#)
    }

    @Test("a part that lies under the keyboard does not count either")
    func androidPartUnderKeyboardDoesNotCount() async throws {
        var tree = Self.badgedCard(badge: FakeUI.frame(214, 300, 180, 40))
        let key = FakeUI.node(.button, label: "q", frame: FakeUI.frame(0, 340, 40, 50), platform: .android)
        tree.roots.append(FakeUI.node(.keyboard, label: "Keyboard", frame: FakeUI.frame(0, 340, 400, 460), platform: .android, children: [key]))
        tree.windows = [
            UIWindowInfo(id: 1, kind: "application", layer: 0, title: "Playground", active: true, focused: true, package: "com.example", bounds: FakeUI.frame(0, 0, 400, 800)),
            UIWindowInfo(id: 2, kind: "inputMethod", layer: 1, title: "Keyboard", active: false, focused: false, package: nil, bounds: FakeUI.frame(0, 340, 400, 460)),
        ]
        let waited = try await Self.waited("card", in: tree)
        #expect(!waited.met, "only the strip below the badge is left, and the keys take it")
    }

    @Test("describe-ui --summary lists that card on Android rather than counting it as covered")
    func androidSummaryListsBadgedCard() async throws {
        let summary = try await Self.describe(["--summary"], on: FakeDeviceBackend(platform: .android, trees: [Self.badgedCard()]), device: Self.android)
        #expect(summary.contains("group id=card"), "\(summary)")
        #expect(!summary.contains("# covered"), "\(summary)")
    }

    // MARK: A group under what it holds

    static let ownCover = FakeUI.frame(20, 110, 200, 40)
    static let ribbon = FakeUI.frame(26, 100, 300, 60)

    /// A card whose title lies under its own total, the total under a ribbon from outside the card that leaves under 8 pt of it showing; the card's own point is clear.
    static func cardUnderOwnTotal(platform: DevicePlatform, pid: Int? = nil) -> UITree {
        func node(_ role: UIRole, id: String, label: String? = nil, _ frame: UIFrame, order: Int, children: [UINode] = []) -> UINode {
            FakeUI.node(role, id: id, label: label, frame: frame, platform: platform, drawingOrder: platform == .android ? order : nil, pid: pid, children: children)
        }
        return FakeUI.tree(platform: platform, width: 400, height: 800, [
            node(.group, id: "card", FakeUI.frame(20, 100, 200, 300), order: 1, children: [
                node(.text, id: "card-title", label: "Card Title", FakeUI.frame(20, 120, 5, 20), order: 1),
                node(.text, id: "card-total", label: "Card Total", ownCover, order: 2),
            ]),
            node(.button, id: "ribbon", label: "Ribbon", ribbon, order: 2),
        ])
    }

    @Test("on Android a group whose title is under its own total stays on screen, though the total is under something else")
    func androidGroupUnderOwnContent() async throws {
        let tree = Self.cardUnderOwnTotal(platform: .android)
        #expect(await Self.placement(of: "card-title", in: tree) == .hidden(#"under text "Card Total" (20, 110) 200x40"#))
        #expect(await Self.placement(of: "card-total", in: tree) == .hidden(#"under button "Ribbon" (26, 100) 300x60"#))
        #expect(await Self.placement(of: "card", in: tree) == .front)
    }

    @Test("a cover with an identical copy outside the group is not taken for the group's own, so the group is still out of reach")
    func androidGroupUnderCopyOfOwnContent() async throws {
        let total = Self.android(.text, id: "card-total", label: "Card Total", Self.ownCover, order: 1)
        var copy = total
        copy.native = .android(AndroidNativeAttributes(resourceId: "card-total", drawingOrder: 2))
        let tree = FakeUI.tree(platform: .android, width: 400, height: 800, [
            Self.android(.group, id: "card", FakeUI.frame(20, 100, 200, 300), order: 1, children: [
                total, Self.android(.text, id: "card-title", label: "Card Title", FakeUI.frame(20, 120, 5, 20), order: 2),
            ]),
            copy,
            Self.android(.button, id: "ribbon", label: "Ribbon", Self.ribbon, order: 3),
        ])
        #expect(await Self.placement(of: "card-title", in: tree) == .hidden(#"under text "Card Total" (20, 110) 200x40"#))
        #expect(await Self.placement(of: "card", in: tree) == .hidden(#"under button "Ribbon" (26, 100) 300x60"#))
    }

    @Test("on an iOS simulator the same group stays on screen, by its hit-tests")
    func simulatorGroupUnderOwnContent() async throws {
        let tree = Self.cardUnderOwnTotal(platform: .ios, pid: 42)
        let card = tree.roots[0].children[0]
        let backend = HitTestingFakeBackend(trees: [tree])
        backend.hits = { point in
            if Self.ribbon.contains(point) { return tree.roots[0].children[1] }
            return Self.ownCover.contains(point) ? card.children[1] : card
        }
        let judged = await Verifier.judged(tree, id: "card", backend: backend, device: Self.ios)
        #expect(Verifier.placement(of: "card-title", in: judged) != .front)
        #expect(Verifier.placement(of: "card", in: judged) == .front)
    }

    @Test("a group whose every element is under something from outside it is still out of reach, on both platforms")
    func groupUnderOutsideCoverStaysOut() async throws {
        let cover = FakeUI.frame(0, 90, 400, 80)
        func tree(_ platform: DevicePlatform) -> UITree {
            var tree = Self.cardUnderOwnTotal(platform: platform, pid: platform == .ios ? 42 : nil)
            tree.roots[0].children[1].frame = cover
            return tree
        }
        #expect(await Self.placement(of: "card", in: tree(.android)) == .hidden(#"under button "Ribbon" (0, 90) 400x80"#))

        let simulator = tree(.ios)
        let backend = HitTestingFakeBackend(trees: [simulator])
        backend.hits = { point in cover.contains(point) ? simulator.roots[0].children[1] : simulator.roots[0].children[0] }
        let judged = await Verifier.judged(simulator, id: "card", backend: backend, device: Self.ios)
        #expect(Verifier.placement(of: "card", in: judged) != .front)
    }
}
