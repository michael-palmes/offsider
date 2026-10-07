import Foundation

/// How a cover check knew what is drawn over a tap target.
public enum CoverEvidence: String, Sendable {
    /// The iOS simulator's own hit-test at the tap point.
    case hitTest
    /// Android's drawing order and window layers, walked down to the tap point.
    case drawingOrder
    /// The order the tree lists elements in, which is not how they are drawn: only a guess.
    case treeOrder
}

/// What a selector tap would land on instead of its target.
public struct CoverVerdict: Equatable, Sendable {
    public var cover: UINode
    public var evidence: CoverEvidence
    /// True when the evidence is sure enough to refuse the tap; otherwise it only warns.
    public var isConfident: Bool
    /// The page or covered screen the cover is on.
    public var screen: String?

    public init(cover: UINode, evidence: CoverEvidence, isConfident: Bool, screen: String? = nil) {
        self.cover = cover
        self.evidence = evidence
        self.isConfident = isConfident
        self.screen = screen
    }
}

/// Decides whether a selector tap's point reaches its target, from a hit-test, Android's drawing order or, failing both, tree order.
public enum CoverJudge {
    /// What a tap at `point` on `target` (from `matched`) would reach instead, given the simulator's `hit` if any; nil when it reaches the target.
    public static func judge(
        target: UINode,
        matched: UINode,
        point: UIPoint,
        candidates: [UINode],
        roots: [UINode],
        viewport: UIFrame,
        stack: ScreenStack,
        hit: UINode?
    ) -> CoverVerdict? {
        let context = Context(target: target, matched: matched, point: point, candidates: candidates, roots: roots, viewport: viewport, stack: stack)
        if let hit {
            switch context.judge(hit: hit) {
            case .clear: return nil
            case .cover(let node, let confident): return context.verdict(node, .hitTest, confident: confident)
            case .undecided: break
            }
        } else if target.isAndroidNode, let top = drawnTop(at: point, in: roots, holding: [target, matched], viewport: viewport, stack: stack) {
            switch context.judge(hit: top) {
            case .clear:
                return context.logBoxBelowFrame(viewport: viewport).map { context.verdict($0, .drawingOrder, confident: true) }
            case .cover(let node, let confident): return context.verdict(node, .drawingOrder, confident: confident)
            case .undecided: break
            }
        }
        return context.guess(viewport: viewport).map { context.verdict($0, .treeOrder, confident: false) }
    }

    /// The hit chain when Android's drawing order or window layers order every set of siblings it passes; nil otherwise.
    static func drawnChain(at point: UIPoint, in roots: [UINode]) -> [UINode]? {
        if roots.count > 1, roots.contains(where: { $0.windowLayer == nil }) {
            return nil
        }
        let chain = UITree.hitChain(in: roots, at: point)
        guard !chain.isEmpty else { return nil }
        for (parent, _) in zip(chain, chain.dropFirst()) where parent.children.count > 1 {
            guard UITree.drawingOrders(of: parent.children) != nil else { return nil }
        }
        return chain
    }

    /// The drawn chain's top, looking beneath full-screen hosts with nothing to touch at the point (an Expo dev client's tools button), as Android passes the touch on.
    static func drawnTop(at point: UIPoint, in roots: [UINode], holding targets: [UINode], viewport: UIFrame, stack: ScreenStack) -> UINode? {
        var remaining = roots
        for _ in 0..<8 {
            guard let chain = drawnChain(at: point, in: remaining), let top = chain.last else { return nil }
            let onPage = ScreenStack.index(of: top, in: roots).map { index in stack.pages.contains { $0.content.contains(index) } } ?? false
            guard chain.count > 1, !onPage, !isPlausibleOccluder(top), let frame = top.frame, spans(frame, viewport),
                  !targets.contains(where: { target in top.flattened().contains { $0.isSameElement(as: target) } }) else {
                return top
            }
            remaining = remaining.map { $0.removing(top) }
        }
        return nil
    }

    private static let containerRoles: Set<UIRole> = [.window, .application, .scrollView, .list]

    /// Covers at least 80 percent of the viewport, as a screen's root or backdrop does.
    static func spans(_ frame: UIFrame, _ viewport: UIFrame) -> Bool {
        guard let visible = frame.intersection(viewport) else { return false }
        return visible.area >= 0.8 * viewport.area
    }

    /// A control, or labelled content that is not a container: something a tap on it would visibly reach.
    public static func isPlausibleOccluder(_ node: UINode) -> Bool {
        node.role.isActionable || (node.trimmedLabel != nil && !containerRoles.contains(node.role))
    }

    enum HitJudgement {
        case clear
        case cover(UINode, confident: Bool)
        case undecided
    }

    struct Context {
        let target: UINode
        let matched: UINode
        let point: UIPoint
        let candidates: [UINode]
        let roots: [UINode]
        let viewport: UIFrame
        let stack: ScreenStack
        let flat: [UINode]
        /// The target and the matched element with everything inside them.
        let own: [UINode]

        init(target: UINode, matched: UINode, point: UIPoint, candidates: [UINode], roots: [UINode], viewport: UIFrame, stack: ScreenStack) {
            self.target = target
            self.matched = matched
            self.point = point
            self.candidates = candidates
            self.roots = roots
            self.viewport = viewport
            self.stack = stack
            flat = roots.flatMap { $0.flattened() }
            own = target.flattened() + matched.flattened()
        }

        func verdict(_ node: UINode, _ evidence: CoverEvidence, confident: Bool) -> CoverVerdict {
            let screen = ScreenStack.index(of: node, in: roots).flatMap(stack.screenName(of:))
            return CoverVerdict(cover: node, evidence: evidence, isConfident: confident, screen: screen)
        }

        private func isOwn(_ node: UINode) -> Bool {
            own.contains { $0.isLoosely(node) }
        }

        private func isAncestor(_ node: UINode, of descendant: UINode) -> Bool {
            !node.isSameElement(as: descendant) && node.flattened().contains { $0.isSameElement(as: descendant) }
        }

        /// The page drawn over the target's screen, if the stack shows one.
        private var pageOverTarget: ScreenStack.Page? {
            [target, matched].lazy.compactMap { ScreenStack.index(of: $0, in: roots) }.compactMap(stack.page(over:)).first
        }

        /// The smallest plausible occluder on the page over the point, else the page itself.
        private func cover(on page: ScreenStack.Page) -> UINode {
            let onPage = page.content.sorted().compactMap { $0 < flat.count ? flat[$0] : nil }
            let atPoint = onPage.filter { node in
                node.frame?.contains(point) == true && CoverJudge.isPlausibleOccluder(node)
            }
            return atPoint.min { $0.area < $1.area } ?? flat[page.index]
        }

        /// The hit as an element of the tree, found again when it moved by up to a point between reads.
        private func placed(_ hit: UINode) -> UINode? {
            flat.first { $0.isSameElement(as: hit) } ?? flat.first { $0.isLoosely(hit) }
        }

        /// The target read again after its label ticked: the same role and id, or with no id the same role within a point; never an element the tree names apart.
        private func isOwnHit(_ hit: UINode, placed: UINode?) -> Bool {
            if let placed {
                return isOwn(placed)
            }
            return own.contains { node in
                guard node.role == hit.role else { return false }
                if let id = hit.trimmedID {
                    return node.trimmedID == id
                }
                guard node.trimmedID == nil, let mine = node.frame, let theirs = hit.frame else { return false }
                return mine.isWithinTolerance(of: theirs)
            }
        }

        /// An unplaced hit of the target's role over most of its frame, with no other id: maybe the target moved, so never a confident cover.
        private func mayBeTarget(_ hit: UINode) -> Bool {
            [target, matched].contains { node in
                guard node.role == hit.role, let mine = node.frame, let theirs = hit.frame,
                      node.trimmedID == nil || hit.trimmedID == nil,
                      let overlap = mine.intersection(theirs) else { return false }
                return overlap.area >= 0.8 * max(mine.area, theirs.area)
            }
        }

        /// The application or window root, or a node spanning the viewport around the target: a hit on it says nothing about the point.
        private func isScreenRoot(_ hit: UINode, placed: UINode?) -> Bool {
            let rootRoles: Set<UIRole> = [.application, .window]
            guard let placed else {
                return rootRoles.contains(hit.role) && roots.contains { $0.role == hit.role && $0.label == hit.label }
            }
            guard [target, matched].contains(where: { isAncestor(placed, of: $0) }) else { return false }
            return rootRoles.contains(placed.role) || placed.frame.map { CoverJudge.spans($0, viewport) } == true
        }

        func judge(hit: UINode) -> HitJudgement {
            let placed = placed(hit)
            if isOwn(hit) || isOwnHit(hit, placed: placed) {
                return .clear
            }
            if isScreenRoot(hit, placed: placed) {
                return pageOverTarget.map { .cover(cover(on: $0), confident: true) } ?? .clear
            }
            if let label = hit.trimmedLabel, let frame = hit.frame {
                let carriers = flat.filter { node in
                    !(placed.map { node.isSameElement(as: $0) } ?? false)
                        && (node.role.isActionable || isOwn(node))
                        && node.frame.map { $0.encloses(frame, tolerance: TransitionGuard.frameTolerance) } == true
                        && node.trimmedLabel.map { $0 == label || $0.contains(label) } == true
                }
                if carriers.contains(where: isOwn) {
                    return .clear
                }
                if let carrier = carriers.min(by: { $0.area < $1.area }) {
                    return .cover(carrier, confident: true)
                }
            }
            let node = placed ?? hit
            if let placed, [target, matched].contains(where: { isAncestor(placed, of: $0) }) {
                if !candidates.contains(where: { isAncestor(placed, of: $0) }), pageOverTarget == nil {
                    return .clear
                }
            } else if !node.role.isActionable, let frame = node.frame, let targetFrame = target.frame,
                      targetFrame.encloses(frame, tolerance: TransitionGuard.frameTolerance) {
                let enclosing = candidates.filter { candidate in
                    candidate.role.isActionable && candidate.frame.map { $0.encloses(frame, tolerance: TransitionGuard.frameTolerance) } == true
                }
                return enclosing.min { $0.area < $1.area }.map { .cover($0, confident: false) } ?? .clear
            } else if CoverJudge.isPlausibleOccluder(node) {
                return placed == nil && mayBeTarget(hit) ? .undecided : .cover(node, confident: true)
            }
            if let page = pageOverTarget {
                return .cover(cover(on: page), confident: true)
            }
            if let placed, ![target, matched].contains(where: { isAncestor(placed, of: $0) }) {
                return .cover(placed, confident: false)
            }
            return .undecided
        }

        /// A LogBox toast drawn over the target whose touch area, reaching below its frame, takes the point.
        func logBoxBelowFrame(viewport: UIFrame) -> UINode? {
            candidates.first { candidate in
                guard KnownOverlays.logBoxToast(candidate, viewport: viewport) != nil, candidate.frame?.contains(point) == false else { return false }
                return UITree.zOrder(of: candidate, over: target, in: roots)?.isAbove == true
            }
        }

        /// Without a hit-test or drawing order: a page over the target's screen, else the first candidate neither inside the target nor a backdrop.
        func guess(viewport: UIFrame) -> UINode? {
            if let page = pageOverTarget {
                return cover(on: page)
            }
            let targetFrame = target.frame
            return candidates.first { candidate in
                guard let frame = candidate.frame else { return true }
                if CoverJudge.spans(frame, viewport) { return false }
                guard let targetFrame else { return true }
                return !targetFrame.encloses(frame, tolerance: 0)
            }
        }
    }
}

extension UINode {
    /// The same element read again: role, id and label equal and the frame within a point.
    func isLoosely(_ other: UINode) -> Bool {
        guard role == other.role, id == other.id, label == other.label else { return false }
        switch (frame, other.frame) {
        case (nil, nil):
            return true
        case (let mine?, let theirs?):
            return mine.isWithinTolerance(of: theirs)
        default:
            return false
        }
    }

    var trimmedLabel: String? {
        guard let trimmed = label?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    /// A copy without `node` and what it holds.
    func removing(_ node: UINode) -> UINode {
        var copy = self
        copy.children = children.filter { !$0.isSameElement(as: node) }.map { $0.removing(node) }
        return copy
    }

    var trimmedID: String? {
        guard let trimmed = id?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    var area: Double {
        frame.map { $0.width * $0.height } ?? .infinity
    }
}

extension UIFrame {
    var area: Double { width * height }

    /// Each edge and size within `TransitionGuard.frameTolerance`.
    func isWithinTolerance(of other: UIFrame) -> Bool {
        let tolerance = TransitionGuard.frameTolerance
        return abs(x - other.x) <= tolerance && abs(y - other.y) <= tolerance
            && abs(width - other.width) <= tolerance && abs(height - other.height) <= tolerance
    }
}
