import Foundation

/// How a cover check knew what is drawn over a tap target.
public enum CoverEvidence: String, Sendable {
    /// The iOS simulator's own hit-test at the tap point.
    case hitTest
    /// Android's drawing order and window layers, walked down to the tap point.
    case drawingOrder
    /// The order the tree lists elements in, which is not how they are drawn: only a guess.
    case treeOrder
    /// A LogBox toast's touch area, which reaches beyond the frame the tree gives it.
    case logBoxTouchArea
    /// The iOS simulator's hit-test found a view another process draws over the app, such as a system prompt.
    case otherProcess
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
    /// What a tap at `point` on `target` (from `matched`) would reach instead, given the simulator's `hit` if any and a LogBox toast grown by `logBoxInset`; nil when it reaches the target.
    /// With `otherProcessCovers`, set while the tree shows a prompt's host, a hit from a process the tree does not hold covers.
    public static func judge(
        target: UINode,
        matched: UINode,
        point: UIPoint,
        candidates: [UINode],
        roots: [UINode],
        viewport: UIFrame,
        stack: ScreenStack,
        hit: UINode?,
        logBoxInset: Double = 0,
        otherProcessCovers: Bool = false
    ) -> CoverVerdict? {
        var context = Context(target: target, matched: matched, point: point, candidates: candidates, roots: roots, viewport: viewport, stack: stack)
        context.logBoxInset = logBoxInset
        context.otherProcessCovers = otherProcessCovers
        let judged = judged(context, hit: hit)
        if judged?.isConfident == true {
            return judged
        }
        // A toast's touch area reaches past its frame, so only a confident verdict outweighs it.
        let toast = context.logBoxTouchCover()
        if toast?.isConfident == true {
            return toast
        }
        return judged ?? toast
    }

    /// The verdict from a hit-test, Android's drawing order or tree order alone; nil when the point is clear.
    private static func judged(_ context: Context, hit: UINode?) -> CoverVerdict? {
        if context.otherProcessCovers, let hit, SystemPrompt.isForeign(hit, in: context.roots) {
            return context.verdict(hit, .otherProcess, confident: true)
        }
        if let hit {
            let judgement = context.judge(hit: hit)
            if case .clear = judgement, let outside = context.candidateOutsideScrollView() {
                return context.verdict(outside, .treeOrder, confident: false)
            }
            switch judgement {
            case .clear: return nil
            case .cover(let node, let confident): return context.verdict(node, .hitTest, confident: confident)
            case .guess(let node): return context.verdict(node, .treeOrder, confident: false)
            case .undecided: break
            }
        } else if context.target.isAndroidNode, let judgement = context.drawnJudgement() {
            switch judgement {
            case .clear: return nil
            case .cover(let node, let confident): return context.verdict(node, .drawingOrder, confident: confident)
            case .guess(let node): return context.verdict(node, .treeOrder, confident: false)
            case .undecided: break
            }
        }
        return context.guess(viewport: context.viewport).map { context.verdict($0, .treeOrder, confident: false) }
    }

    /// True only when the simulator's hit-test at `point` answered with the target or something inside it. Android's drawing order is no proof, as React Native leaves an opaque page's background out of the tree.
    public static func surelyReaches(target: UINode, matched: UINode, point: UIPoint, roots: [UINode], viewport: UIFrame, stack: ScreenStack, hit: UINode) -> Bool {
        Context(target: target, matched: matched, point: point, candidates: [], roots: roots, viewport: viewport, stack: stack).isOwnHit(hit)
    }

    /// What Android's drawing order surely draws over target at point: the cover a selector tap refuses outright; nil when the point reaches it or the order cannot tell.
    public static func drawnCover(of target: UINode, at point: UIPoint, roots: [UINode], viewport: UIFrame, stack: ScreenStack) -> UINode? {
        guard target.isAndroidNode else { return nil }
        let context = Context(target: target, matched: target, point: point, candidates: [], roots: roots, viewport: viewport, stack: stack)
        guard case .cover(let node, confident: true)? = context.drawnJudgement() else { return nil }
        return node
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

    /// The drawn chain's top, looking beneath full-screen views with nothing to touch at the point (an Expo dev client's tools button), as Android passes the touch on.
    static func drawnTop(at point: UIPoint, in roots: [UINode], holding targets: [UINode], viewport: UIFrame, stack: ScreenStack) -> UINode? {
        let targetsPage = targets.lazy.compactMap { ScreenStack.index(of: $0, in: roots) }.compactMap(stack.page(holding:)).first
        var remaining = roots
        for _ in 0..<8 {
            guard let chain = drawnChain(at: point, in: remaining), let top = chain.last else { return nil }
            let holdsTarget = targets.contains { target in top.flattened().contains { $0.isSameElement(as: target) } }
            // In Compose a node that takes no taps hands the touch to what lies beneath it, as a row's text does to the button beside it.
            if chain.count > 1, !holdsTarget, !top.isActionable, isComposeNode(in: chain) {
                remaining = remaining.map { $0.removing(top) }
                continue
            }
            guard chain.count > 1, !isPlausibleOccluder(top), passesTouch(top, in: chain, roots: roots, stack: stack, targetsPage: targetsPage),
                  let frame = top.frame, spans(frame, viewport), !holdsTarget else {
                return top
            }
            remaining = remaining.map { $0.removing(top) }
        }
        return nil
    }

    /// A native host off every page passes the touch on; a React Native view only on the target's own page, never the page itself.
    private static func passesTouch(_ node: UINode, in chain: [UINode], roots: [UINode], stack: ScreenStack, targetsPage: ScreenStack.Page?) -> Bool {
        let index = ScreenStack.index(of: node, in: roots)
        let react = isReactView(node, in: chain)
        if let index, let page = targetsPage, index != page.index, page.content.contains(index) {
            return react
        }
        return !react && !(index.map { index in stack.pages.contains { $0.content.contains(index) } } ?? false)
    }

    /// A node of a Jetpack Compose host, which takes touches only where a modifier handles them.
    static func isComposeNode(in chain: [UINode]) -> Bool {
        chain.contains { $0.androidClassName?.hasPrefix("androidx.compose.") == true }
    }

    /// The classes Android names a React Native view by: `ReactViewGroup`'s own, or a role's.
    private static let reactViewClasses: Set<String> = ["android.view.ViewGroup", "android.view.View"]

    /// A React Native view outside a Compose host (whose nodes are `android.view.View` too): React takes its touches in JavaScript, so nothing passes beneath it.
    static func isReactView(_ node: UINode, in chain: [UINode]) -> Bool {
        guard let className = node.androidClassName else { return false }
        if className.hasPrefix("com.facebook.react.") { return true }
        return reactViewClasses.contains(className) && !isComposeNode(in: chain)
    }

    private static let containerRoles: Set<UIRole> = [.window, .application, .scrollView, .list]

    /// True when `area` overlaps `frame` by a point or more of height.
    public static func reaches(_ area: UIFrame, _ frame: UIFrame?) -> Bool {
        guard let frame, let overlap = area.intersection(frame) else { return false }
        return overlap.height >= 1
    }

    /// Covers at least 80 percent of the viewport, as a screen's root or backdrop does.
    static func spans(_ frame: UIFrame, _ viewport: UIFrame) -> Bool {
        guard let visible = frame.intersection(viewport) else { return false }
        return visible.area >= 0.8 * viewport.area
    }

    /// A control, or labelled content that is not a container: something a tap on it would visibly reach. Unlabelled groups wrap content rather than draw over it.
    public static func isPlausibleOccluder(_ node: UINode) -> Bool {
        node.role.isActionable || (node.normalizedLabel != nil && !containerRoles.contains(node.role))
    }

    /// An unlabelled group holding controls, such as a tab bar or a footer bar, whose padding takes a touch though nothing in it is labelled there.
    public static func isBar(_ node: UINode) -> Bool {
        !node.role.isActionable && node.normalizedLabel == nil && !containerRoles.contains(node.role) && node.role != .keyboard
            && node.children.contains { $0.flattened().contains { $0.role.isActionable } }
    }

    /// A bar at `point`, nearly as wide as the screen and at most a quarter of its height, that does not lie inside `target`: something drawn over the target there.
    public static func isBar(_ node: UINode, over target: UINode, at point: UIPoint, viewport: UIFrame) -> Bool {
        guard isBar(node), let frame = node.frame, frame.contains(point),
              frame.width >= 0.8 * viewport.width, frame.height <= viewport.height / 4 else { return false }
        return target.frame.map { !$0.encloses(frame, tolerance: TransitionGuard.frameTolerance) } ?? true
    }

    enum HitJudgement {
        case clear
        case cover(UINode, confident: Bool)
        /// Only tree order points at it.
        case guess(UINode)
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
        /// Scroll indicators, which take no taps.
        let indicators: [UINode]
        var logBoxInset = 0.0
        var otherProcessCovers = false

        init(target: UINode, matched: UINode, point: UIPoint, candidates: [UINode], roots: [UINode], viewport: UIFrame, stack: ScreenStack) {
            let indicators = ScrollIndicator.all(in: roots)
            self.target = target
            self.matched = matched
            self.point = point
            self.candidates = candidates.filter { candidate in !indicators.contains { $0.isSameElement(as: candidate) } }
            self.roots = roots
            self.viewport = viewport
            self.stack = stack
            self.indicators = indicators
            flat = roots.flatMap { $0.flattened() }
            own = target.flattened() + matched.flattened()
        }

        /// The judgement of what Android's drawing order puts on top at the point; nil when the order cannot tell.
        func drawnJudgement() -> HitJudgement? {
            CoverJudge.drawnTop(at: point, in: roots, holding: [target, matched], viewport: viewport, stack: stack).map(judge(hit:))
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
            [target, matched].lazy.compactMap { stack.page(over: $0, in: roots) }.first
        }

        /// The smallest plausible occluder on the page over the point, else the page itself.
        private func cover(on page: ScreenStack.Page) -> UINode {
            let onPage = page.content.sorted().compactMap { $0 < flat.count ? flat[$0] : nil }
            let atPoint = onPage.filter { node in
                node.frame?.contains(point) == true && CoverJudge.isPlausibleOccluder(node) && !indicators.contains { $0.isSameElement(as: node) }
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
                if let id = hit.normalizedID {
                    return node.normalizedID == id
                }
                guard node.normalizedID == nil, let mine = node.frame, let theirs = hit.frame else { return false }
                return mine.isWithinTolerance(of: theirs)
            }
        }

        /// Another labelled element in the labelled target's own place, which the hit names: the next page's title over this one's.
        private func elementNamed(by hit: UINode, placed: UINode?) -> UINode? {
            guard let label = hit.normalizedLabel, let frame = hit.frame, let targetFrame = target.frame,
                  let mine = target.normalizedLabel, !mine.contains(label), !label.contains(mine) else { return nil }
            func isOther(_ node: UINode) -> Bool {
                !isOwn(node) && ![target, matched].contains(where: { isAncestor(node, of: $0) })
            }
            if let placed {
                return placed.frame.map { $0.isWithinTolerance(of: targetFrame) } == true && isOther(placed) ? placed : nil
            }
            return flat.first { node in
                node.normalizedLabel == label && node.frame.map { $0.isWithinTolerance(of: frame) } == true && isOther(node)
            }
        }

        /// A screen-filling group with an id, other than the target and holding neither it nor what it matched: a page whose own area took the touch.
        private func pageGroup(_ placed: UINode?) -> UINode? {
            guard let placed, placed.normalizedID != nil, placed.normalizedLabel == nil, !placed.role.isActionable,
                  !CoverJudge.containerRoles.contains(placed.role), !isOwn(placed),
                  ![target, matched].contains(where: { isAncestor(placed, of: $0) }),
                  let frame = placed.frame, CoverJudge.spans(frame, viewport) else { return nil }
            return placed
        }

        /// The hit is the target or inside it.
        func isOwnHit(_ hit: UINode) -> Bool {
            isOwn(hit) || isOwnHit(hit, placed: placed(hit))
        }

        /// An unplaced hit of the target's role over most of its frame, with no other id: maybe the target moved, so never a confident cover.
        private func mayBeTarget(_ hit: UINode) -> Bool {
            [target, matched].contains { node in
                guard node.role == hit.role, let mine = node.frame, let theirs = hit.frame,
                      node.normalizedID == nil || hit.normalizedID == nil,
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

        /// A hit on a scroll indicator, placed in the tree or lying along one of its scroll views.
        private func isIndicator(_ hit: UINode, placed: UINode?) -> Bool {
            guard let placed else { return ScrollIndicator.isIndicator(hit, alongAnyScrollViewIn: roots) }
            return indicators.contains { $0.isSameElement(as: placed) }
        }

        func judge(hit: UINode) -> HitJudgement {
            let placed = placed(hit)
            if isOwn(hit) || isOwnHit(hit, placed: placed) {
                return .clear
            }
            if let other = elementNamed(by: hit, placed: placed) {
                return .cover(other, confident: true)
            }
            if let page = pageGroup(placed) {
                return .cover(page, confident: true)
            }
            // An unlabelled container holds what lies inside its frame, which an iOS simulator lists beside it rather than within.
            if !target.isActionable, target.normalizedLabel == nil, pageOverTarget == nil, let mine = target.frame, let theirs = (placed ?? hit).frame,
               mine.encloses(theirs, tolerance: TransitionGuard.frameTolerance) {
                return .clear
            }
            if isIndicator(hit, placed: placed) {
                return .undecided
            }
            if isScreenRoot(hit, placed: placed) {
                if let page = pageOverTarget {
                    return .cover(cover(on: page), confident: true)
                }
                return controlOverPoint().map { .guess($0) } ?? .clear
            }
            if let label = hit.normalizedLabel, let frame = hit.frame {
                // An ancestor of the target holds it, so it never covers it, whatever label it merges.
                let carriers = flat.filter { node in
                    !(placed.map { node.isSameElement(as: $0) } ?? false)
                        && ![target, matched].contains(where: { isAncestor(node, of: $0) })
                        && (node.role.isActionable || isOwn(node))
                        && node.frame.map { $0.encloses(frame, tolerance: TransitionGuard.frameTolerance) } == true
                        && node.normalizedLabel.map { $0 == label || $0.contains(label) } == true
                }
                if carriers.contains(where: isOwn) {
                    return .clear
                }
                if let carrier = carriers.min(by: { $0.area < $1.area }) {
                    return .cover(carrier, confident: true)
                }
            }
            let node = placed ?? hit
            if let placed, ![target, matched].contains(where: { isAncestor(placed, of: $0) }), CoverJudge.isBar(placed, over: target, at: point, viewport: viewport) {
                return .cover(placed, confident: true)
            }
            if let placed, [target, matched].contains(where: { isAncestor(placed, of: $0) }) {
                if !candidates.contains(where: { isAncestor(placed, of: $0) }), pageOverTarget == nil {
                    return .clear
                }
            } else if !node.role.isActionable, !(placed?.isAndroidNode ?? false), let frame = node.frame, let targetFrame = target.frame,
                      targetFrame.encloses(frame, tolerance: TransitionGuard.frameTolerance) {
                // An iOS simulator lists what a target draws beside it; Android nests it, so a node placed elsewhere there is never the target's own.
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

        /// The nearest scroll view or list holding the target or the matched element.
        private var scrollAncestor: UINode? {
            for node in [target, matched] {
                guard let path = UITree.indexPath(to: node, in: roots) else { continue }
                var chain = [roots[path[0]]]
                for index in path.dropFirst() {
                    chain.append(chain[chain.count - 1].children[index])
                }
                if let scroll = chain.dropLast().last(where: { [.scrollView, .list].contains($0.role) }) {
                    return scroll
                }
            }
            return nil
        }

        /// The smallest candidate at the point outside the target's scroll view, such as a footer floating over it: a hit-test may answer with what the scroll view holds beneath it.
        func candidateOutsideScrollView() -> UINode? {
            guard let scroll = scrollAncestor else { return nil }
            let inside = scroll.flattened()
            return candidates.filter { candidate in
                guard !isOwn(candidate), let frame = candidate.frame, frame.contains(point), !CoverJudge.spans(frame, viewport),
                      !inside.contains(where: { $0.isSameElement(as: candidate) }),
                      !candidate.flattened().contains(where: { $0.isSameElement(as: scroll) }) else { return false }
                return scroll.frame.map { !frame.encloses($0, tolerance: 0) } ?? true
            }.min { $0.area < $1.area }
        }

        /// The first control over the point that is neither the target's own, inside its frame, nor a backdrop: a root hit says nothing, so it is only a guess.
        private func controlOverPoint() -> UINode? {
            candidates.first { candidate in
                guard candidate.role.isActionable, !isOwn(candidate), let frame = candidate.frame, !CoverJudge.spans(frame, viewport) else { return false }
                return target.frame.map { !$0.encloses(frame, tolerance: 0) } ?? true
            }
        }

        /// A LogBox toast over the target whose touch area takes the point beyond its frame; a guess when that area only reaches the target's frame.
        func logBoxTouchCover() -> CoverVerdict? {
            let toasts = candidates.compactMap { candidate -> (node: UINode, area: UIFrame)? in
                guard let area = KnownOverlays.logBoxTouchArea(of: candidate, in: viewport, inset: logBoxInset), !stack.isBeneath(candidate, in: roots),
                      UITree.zOrder(of: candidate, over: target, in: roots)?.isAbove == true else { return nil }
                return (candidate, area)
            }
            if let taking = toasts.first(where: { $0.area.contains(point) && $0.node.frame?.contains(point) == false }) {
                return verdict(taking.node, .logBoxTouchArea, confident: true)
            }
            return toasts.first { CoverJudge.reaches($0.area, target.frame) }.map { verdict($0.node, .logBoxTouchArea, confident: false) }
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

    var androidClassName: String? {
        guard case .android(let attributes) = native else { return nil }
        return attributes.className
    }

    /// A copy without `node` and what it holds.
    func removing(_ node: UINode) -> UINode {
        var copy = self
        copy.children = children.filter { !$0.isSameElement(as: node) }.map { $0.removing(node) }
        return copy
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
