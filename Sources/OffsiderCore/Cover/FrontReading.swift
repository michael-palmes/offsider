import Foundation

/// The elements a touch at their activation point would not reach, as the one on-screen judgement found them: selectors, `wait`, `assert` and `describe-ui --on-screen` all read it.
public struct FrontReading: Equatable, Sendable {
    /// The name of the page drawn over an element's screen, by the element's pre-order index over the tree's roots.
    public var beneath: [Int: String]
    /// What a touch at an element's point surely reaches instead, by its pre-order index.
    public var covered: [Int: CoverVerdict]
    /// Each element judged by a touch, covered or not, so a tap at the same point needs no second hit-test.
    public var judged: [Int: Judged]

    /// The point judged and the judge's verdict there, a guess included; nil when the touch reaches the element.
    public struct Judged: Equatable, Sendable {
        public var point: UIPoint
        public var verdict: CoverVerdict?

        public init(point: UIPoint, verdict: CoverVerdict?) {
            self.point = point
            self.verdict = verdict
        }
    }

    public init(beneath: [Int: String] = [:], covered: [Int: CoverVerdict] = [:], judged: [Int: Judged] = [:]) {
        self.beneath = beneath
        self.covered = covered
        self.judged = judged
    }

    public var isEmpty: Bool { beneath.isEmpty && covered.isEmpty }

    /// Pre-order indexes of every element a touch would not reach.
    public var unreached: Set<Int> { Set(beneath.keys).union(covered.keys) }

    /// True when a touch at the element at `index` lands elsewhere: a sure cover, or anything else the simulator's own hit-test answered with.
    public func misses(at index: Int) -> Bool {
        unreached.contains(index) || judged[index]?.verdict?.evidence == .hitTest
    }

    /// Why a touch at the element at `index` would not reach it, such as `beneath "Products"` or `under button "Buy" (16, 790.0) 370x44`; nil when it would.
    public func reason(at index: Int) -> String? {
        if let page = beneath[index] {
            return "beneath \(UITreeRenderer.quoted(SelectorText.truncated(page, limit: 40)))"
        }
        guard let verdict = covered[index] else { return nil }
        var parts = ["under", verdict.cover.role.rawValue]
        if let name = verdict.cover.normalizedLabel.map({ OutputMasks.current.mask.shownLabel($0, id: verdict.cover.normalizedID) }) ?? verdict.cover.normalizedID {
            parts.append(UITreeRenderer.quoted(SelectorText.truncated(name, limit: 40)))
        }
        if let frame = verdict.cover.frame {
            parts.append(frame.summary)
        }
        return parts.joined(separator: " ")
    }

    /// `reason(at:)` for `node` of `roots`; nil when any identical copy of it is reached.
    public func reason(for node: UINode, in roots: [UINode]) -> String? {
        guard !isEmpty else { return nil }
        let reasons = ScreenStack.indexes(of: node, in: roots).map(reason(at:))
        guard !reasons.isEmpty, !reasons.contains(where: { $0 == nil }) else { return nil }
        return reasons[0]
    }
}
