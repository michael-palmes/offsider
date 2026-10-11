import Foundation
import OffsiderCore
import Testing
@testable import Offsider

@Suite("Scroll indicators")
@MainActor
struct ScrollIndicatorTests {
    static let device = DeviceID(rawValue: "fake-device", platform: .ios)
    nonisolated static let englishLabel = "Horizontal scroll bar, 1 page"
    nonisolated static let frenchLabel = "Barre de défilement horizontale, 1 page"
    static let indicatorFrame = FakeUI.frame(62, 841, 278, 30)

    /// A scroll view reaching under a tab bar, with the system indicators iOS lists inside it; listed last, so the fake's point read finds the indicator over Tab Two.
    static func tabsUnderScrollView(indicator: UINode? = nil, wrapped: Bool = false) -> UITree {
        let across = indicator ?? FakeUI.node(.slider, label: englishLabel, value: "0%", frame: indicatorFrame)
        let upright = FakeUI.node(.slider, label: "Vertical scroll bar, 3 pages", value: "0%", frame: FakeUI.frame(369, 106, 30, 735))
        let content = FakeUI.node(.group, frame: FakeUI.frame(0, 106, 402, 2000), children: [
            FakeUI.node(.button, id: "row-1", label: "Row 1", frame: FakeUI.frame(0, 106, 402, 64)),
        ])
        let scrollChildren = wrapped
            ? [content, upright, FakeUI.node(.group, frame: FakeUI.frame(0, 106, 402, 768), children: [across])]
            : [content, upright, across]
        let scrollView = FakeUI.node(.scrollView, frame: FakeUI.frame(0, 106, 402, 768), children: scrollChildren)
        let tabs = FakeUI.node(.tabBar, frame: FakeUI.frame(0, 820, 402, 54), children: [
            FakeUI.node(.button, id: "tab-one", label: "Tab One", frame: FakeUI.frame(0, 820, 134, 54)),
            FakeUI.node(.button, id: "tab-two", label: "Tab Two", frame: FakeUI.frame(134, 820, 134, 54)),
        ])
        return FakeUI.tree(width: 402, height: 874, [tabs, scrollView])
    }

    static func slider(in tree: UITree) throws -> UINode {
        try #require(tree.roots.flatMap { $0.flattened() }.last { $0.role == .slider })
    }

    @Test("a scroll indicator over a tab is never a cover candidate, in any language", arguments: [englishLabel, frenchLabel])
    func indicatorIsNoCandidate(label: String) throws {
        let tree = Self.tabsUnderScrollView(indicator: FakeUI.node(.slider, label: label, value: "0%", frame: Self.indicatorFrame))

        let resolution = try AccessibilityTargetResolver.resolveTap(roots: tree.roots, query: .label("Tab Two"))

        #expect(resolution.point.x == 201 && resolution.point.y == 847)
        #expect(resolution.coverCandidates.isEmpty)
    }

    @Test("a hit-test answering with a scroll indicator is no cover, even when the caller lists it as a candidate", arguments: [englishLabel, frenchLabel])
    func indicatorHitIsNoCover(label: String) throws {
        let tree = Self.tabsUnderScrollView(indicator: FakeUI.node(.slider, label: label, value: "0%", frame: Self.indicatorFrame))
        let indicator = try Self.slider(in: tree)

        #expect(try TapCoverTests.judge(tree, target: "tab-two", hit: indicator) == nil)
        #expect(try TapCoverTests.judge(tree, target: "tab-two", hit: nil) == nil)
        var moved = indicator
        moved.value = "40%"
        moved.frame = FakeUI.frame(62, 842.5, 278, 30)
        #expect(try TapCoverTests.judge(tree, target: "tab-two", hit: moved) == nil)
    }

    @Test("tap --fail-if-covered on a tab under a scroll indicator goes ahead without a hit-test")
    func failIfCoveredTapsTab() async throws {
        let tree = Self.tabsUnderScrollView()
        let backend = HitTestingFakeBackend(trees: [tree])
        let resolution = try AccessibilityTargetResolver.resolveTap(roots: tree.roots, query: .label("Tab Two"))

        try await TapCover(failIfCovered: true).check(resolution, selector: "--label 'Tab Two'", tree: tree, backend: backend, device: Self.device)

        #expect(backend.hitTests == 0)
    }

    enum Lookalike: String, CaseIterable, CustomTestStringConvertible {
        case withID, thick, notDirectChild, awayFromEdge
        var testDescription: String { rawValue }
    }

    @Test("a slider that only looks like an indicator stays a cover", arguments: Lookalike.allCases)
    func lookalikeStaysCover(lookalike: Lookalike) throws {
        let label = Self.englishLabel
        let tree: UITree
        switch lookalike {
        case .withID: tree = Self.tabsUnderScrollView(indicator: FakeUI.node(.slider, id: "volume", label: label, frame: Self.indicatorFrame))
        case .thick: tree = Self.tabsUnderScrollView(indicator: FakeUI.node(.slider, label: label, frame: FakeUI.frame(62, 827, 278, 44)))
        case .notDirectChild: tree = Self.tabsUnderScrollView(wrapped: true)
        case .awayFromEdge: tree = Self.tabsUnderScrollView(indicator: FakeUI.node(.slider, label: label, frame: FakeUI.frame(62, 834, 278, 30)))
        }
        let slider = try Self.slider(in: tree)

        let resolution = try AccessibilityTargetResolver.resolveTap(roots: tree.roots, query: .label("Tab Two"))
        let verdict = try #require(try TapCoverTests.judge(tree, target: "tab-two", hit: slider))

        #expect(resolution.coverCandidates.map(\.label) == [label])
        #expect(verdict.cover.label == label && verdict.isConfident)
    }

    nonisolated static let iosGoldens = TreeGoldens.all().filter { $0.platform == .ios }

    @Test("the system scroll bars in the iOS goldens are the indicators found, and the playground's own slider is not", arguments: iosGoldens)
    nonisolated func goldenIndicators(golden: TreeGoldens.Golden) throws {
        let nodes = try TreeGoldens.tree(of: golden).roots.flatMap { $0.flattened() }
        let found = ScrollIndicator.all(in: try TreeGoldens.tree(of: golden).roots)

        #expect(found.count == nodes.filter { $0.label?.contains("scroll bar") == true }.count)
        #expect(found.allSatisfy { $0.label?.contains("scroll bar") == true })
    }

    @Test("no tap on any control in the iOS goldens lists a scroll bar as a cover candidate")
    nonisolated func goldenTapsNeverListIndicators() throws {
        var underIndicator = 0
        for golden in Self.iosGoldens {
            let tree = try TreeGoldens.tree(of: golden)
            let nodes = tree.roots.flatMap { $0.flattened() }
            let bars = nodes.filter { $0.label?.contains("scroll bar") == true }.compactMap(\.frame)
            for control in nodes where control.role.isActionable && control.role != .slider {
                guard let id = control.normalizedID else { continue }
                let query: AccessibilityQuery = control.normalizedLabel.map { .all(.id(id), refinedBy: [.label($0)]) } ?? .id(id)
                guard let resolution = try? AccessibilityTargetResolver.resolveTap(roots: tree.roots, query: query) else { continue }
                let point = UIPoint(x: resolution.point.x, y: resolution.point.y)
                if bars.contains(where: { $0.contains(point) }) {
                    underIndicator += 1
                }
                #expect(!resolution.coverCandidates.contains { $0.label?.contains("scroll bar") == true }, "\(golden.name): \(id)")
            }
        }
        #expect(underIndicator > 0)
    }
}
