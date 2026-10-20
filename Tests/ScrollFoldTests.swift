import Foundation
import OffsiderCore
import Testing
@testable import Offsider

@Suite("Taps inside scroll views")
@MainActor
struct ScrollFoldTests {
    static let device = DeviceID(rawValue: "fake-device", platform: .ios)

    static func row(_ number: Int, y: Double, height: Double = 60, platform: DevicePlatform = .ios) -> UINode {
        FakeUI.node(.button, id: "menu-row-\(number)", label: "Menu Row \(number)", frame: FakeUI.frame(0, y, 402, height), platform: platform)
    }

    /// A menu whose scroll view ends at 750, above a footer button pinned below it.
    static func pinnedFooter(rows: [UINode]) -> UITree {
        let scrollView = FakeUI.node(.scrollView, frame: FakeUI.frame(0, 100, 402, 650), children: [
            FakeUI.node(.group, frame: FakeUI.frame(0, 100, 402, 1200), children: rows),
        ])
        let footer = FakeUI.node(.button, id: "menu-footer", label: "Continue", frame: FakeUI.frame(16, 760, 370, 56))
        return FakeUI.tree(width: 402, height: 874, [scrollView, footer])
    }

    static func resolutionError(_ body: () throws -> Void) -> ElementResolutionError? {
        do {
            try body()
            return nil
        } catch {
            return error as? ElementResolutionError
        }
    }

    @Test("a row wholly below its scroll view's fold, though inside the screen, is off screen and names the fold")
    func rowBelowFoldIsOffScreen() {
        let tree = Self.pinnedFooter(rows: [Self.row(1, y: 100), Self.row(12, y: 760)])

        let error = Self.resolutionError { _ = try AccessibilityTargetResolver.resolveTap(roots: tree.roots, query: .label("Menu Row 12")) }

        #expect(error?.reason == .targetOffScreen)
        #expect(error?.isRetryable == true)
        #expect(error?.userFacingDescription.hasPrefix("Matched --label 'Menu Row 12' is below the fold of its scroll view; scroll first: its frame (0, 760) 402x60 is outside the (0, 100) 402x650 the scroll view shows") == true)
    }

    @Test("a row with only a sliver above the fold is off screen too")
    func sliverIsOffScreen() {
        let tree = Self.pinnedFooter(rows: [Self.row(11, y: 745)])

        let error = Self.resolutionError { _ = try AccessibilityTargetResolver.resolveTap(roots: tree.roots, query: .id("menu-row-11")) }

        #expect(error?.reason == .targetOffScreen)
    }

    @Test("a row straddling the fold is tapped in the middle of the part the scroll view shows, clear of the footer")
    func straddlingRowIsClipped() async throws {
        let tree = Self.pinnedFooter(rows: [Self.row(11, y: 720)])
        let backend = HitTestingFakeBackend(trees: [tree])

        let resolution = try AccessibilityTargetResolver.resolveTap(roots: tree.roots, query: .id("menu-row-11"))
        try await TapCover(failIfCovered: true).check(resolution, selector: "--id 'menu-row-11'", tree: tree, backend: backend, device: Self.device)

        #expect(resolution.point.x == 201 && resolution.point.y == 735)
        #expect(resolution.coverCandidates.isEmpty)
    }

    @Test("a card in a carousel inside a list is clipped by the list's fold and the screen's edge")
    func carouselInsideList() throws {
        let card = FakeUI.node(.button, id: "card-3", label: "Card 3", frame: FakeUI.frame(300, 630, 200, 140))
        let carousel = FakeUI.node(.scrollView, frame: FakeUI.frame(0, 620, 402, 160), children: [card])
        let list = FakeUI.node(.list, frame: FakeUI.frame(0, 100, 402, 600), children: [carousel])
        let tree = FakeUI.tree(width: 402, height: 874, [list])

        let resolution = try AccessibilityTargetResolver.resolveTap(roots: tree.roots, query: .id("card-3"))

        #expect(resolution.point.x == 351 && resolution.point.y == 665)
    }

    @Test("a card peeking past a carousel's side, still on screen, is tapped where it shows, since carousels may draw past their sides")
    func peekingCardIsTapped() throws {
        let card = FakeUI.node(.button, id: "card-2", label: "Card 2", frame: FakeUI.frame(310, 640, 90, 120))
        let carousel = FakeUI.node(.scrollView, frame: FakeUI.frame(0, 620, 300, 160), children: [card])
        let tree = FakeUI.tree(width: 402, height: 874, [carousel])

        let resolution = try AccessibilityTargetResolver.resolveTap(roots: tree.roots, query: .id("card-2"))

        #expect(resolution.point.x == 355 && resolution.point.y == 700)
    }

    @Test("--allow-offscreen taps the row's own centre below the fold")
    func allowOffscreenBypassesFold() throws {
        let tree = Self.pinnedFooter(rows: [Self.row(12, y: 760)])

        let resolution = try AccessibilityTargetResolver.resolveTap(roots: tree.roots, query: .id("menu-row-12"), allowOffscreen: true)

        #expect(resolution.point.x == 201 && resolution.point.y == 790)
    }

    /// A footer floating over the bottom of a scroll view that reaches the screen's foot; listed first, so the fake's point read answers with the row beneath it.
    static func floatingFooter(platform: DevicePlatform = .ios) -> UITree {
        let scrollView = FakeUI.node(.scrollView, frame: FakeUI.frame(0, 100, 402, 774), platform: platform, drawingOrder: 2, children: [
            Self.row(12, y: 780, platform: platform),
        ])
        let footer = FakeUI.node(.button, id: "menu-footer", label: "Continue", frame: FakeUI.frame(16, 790, 370, 56), platform: platform, drawingOrder: 1)
        return FakeUI.tree(platform: platform, width: 402, height: 874, [footer, scrollView])
    }

    @Test("on iOS a hit-test answering with the row under a floating footer is only a guess, so --fail-if-covered refuses and sends nothing")
    func floatingFooterIsGuessOnIOS() async throws {
        let tree = Self.floatingFooter()
        let backend = HitTestingFakeBackend(trees: [tree])
        let resolution = try AccessibilityTargetResolver.resolveTap(roots: tree.roots, query: .id("menu-row-12"))

        let error = await #expect(throws: CLIError.self) {
            try await TapCover(failIfCovered: true).check(resolution, selector: "--id 'menu-row-12'", tree: tree, backend: backend, device: Self.device)
        }

        #expect(backend.hitTests == 1)
        #expect(error?.reason == .targetCovered)
        #expect(error?.userFacingDescription == "--id 'menu-row-12' at (201, 810) may be covered by button \"Continue\" (16, 790) 370x56; the tap may land on it.")
        #expect(error?.coveredBy?.evidence == .treeOrder)
        #expect(backend.session.calls.isEmpty)
    }

    @Test("Android's drawing order putting the scroll view over the footer stays clear")
    func floatingFooterClearByDrawingOrder() throws {
        #expect(try TapCoverTests.judge(Self.floatingFooter(platform: .android), target: "menu-row-12", hit: nil) == nil)
        #expect(try TapCoverTests.judge(Self.floatingFooter(), target: "menu-row-12", hit: Self.row(12, y: 780))?.isConfident == false)
    }
}
