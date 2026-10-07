import Foundation
import OffsiderCore

enum AccessibilityQuery {
    case id(String)
    case label(String)
    case value(String)

    var allowsSiblingRedirection: Bool {
        switch self {
        case .label:
            return true
        case .id, .value:
            return false
        }
    }

    /// Labels and values match after folding quotes and spaces; ids stay exact.
    var allowsFolding: Bool {
        switch self {
        case .label, .value:
            return true
        case .id:
            return false
        }
    }

    var kind: String {
        switch self {
        case .id: return "--id"
        case .label: return "--label"
        case .value: return "--value"
        }
    }

    var rawValue: String {
        switch self {
        case .id(let value), .label(let value), .value(let value):
            return value
        }
    }

    var selectorDescription: String {
        "\(kind) '\(rawValue)'"
    }

    /// The trimmed field this query reads from `node`.
    func field(of node: UINode) -> String? {
        switch self {
        case .id: return node.normalizedID
        case .label: return node.normalizedLabel
        case .value: return node.isSecure ? nil : node.normalizedValue
        }
    }
}

/// One candidate element, as an error lists it; never its value.
struct MatchSummary: Equatable {
    let role: UIRole
    let id: String?
    let label: String?
    let frame: UIFrame?
    /// Nil when the tree has no screen to compare with.
    let isOnScreen: Bool?
    /// Its place among the on-screen matches, the number `tap --nth` takes.
    var index: Int? = nil
    /// The title of the window (Android) or app it is in.
    var window: String? = nil
    /// The screen it is on: a covered screen's or page's name, else the id of the nearest ancestor that fills the screen.
    var screen: String? = nil
    /// True when a page is drawn over it; nil when no page covers anything.
    var beneath: Bool? = nil

    init(role: UIRole, id: String?, label: String? = nil, frame: UIFrame?, isOnScreen: Bool?) {
        self.role = role
        self.id = id
        self.label = label
        self.frame = frame
        self.isOnScreen = isOnScreen
    }

    init(_ node: UINode, viewport: UIFrame?, index: Int? = nil, roots: [UINode] = [], stack: ScreenStack = .empty) {
        self.init(
            role: node.role,
            id: node.normalizedID,
            label: node.normalizedLabel.map { SelectorText.truncated($0) },
            frame: node.frame,
            isOnScreen: viewport.map { node.frame?.isVisible(in: $0) == true }
        )
        self.index = index
        let ancestors = AccessibilityTargetResolver.ancestorsOf(node, in: roots)
        window = ancestors.first?.normalizedLabel.map { SelectorText.truncated($0) }
        if let viewport {
            screen = ancestors.reversed().first { ancestor in
                ancestor.normalizedID != nil && ancestor.frame.map { AccessibilityTargetResolver.isBackdrop($0, in: viewport) } == true
            }?.normalizedID
        }
        if !stack.beneath.isEmpty, let position = ScreenStack.index(of: node, in: roots) {
            beneath = stack.isBeneath(index: position)
            screen = stack.screenName(of: position).map { SelectorText.truncated($0) } ?? screen
        }
    }

    var text: String {
        var parts = [role.rawValue]
        if let id { parts.append("id=\(id)") }
        if let label { parts.append("label=\"\(label)\"") }
        parts.append(frame?.summary ?? "with no frame")
        if isOnScreen == false { parts.append("off screen") }
        if let screen { parts.append("in screen=\(screen)") }
        if beneath == true { parts.append("(beneath another screen)") }
        if let index { parts.append("(--nth \(index))") }
        return parts.joined(separator: " ")
    }

    var failureCandidate: FailureCandidate {
        FailureCandidate(id: id, label: label, role: role.rawValue, frame: frame, onScreen: isOnScreen, index: index, window: window, screen: screen, beneath: beneath)
    }
}

enum ElementResolutionError: LocalizedError, UserFacingError, OffsiderFailure {
    /// `candidates` are the elements behind `suggestions`.
    case notFound(kind: String, value: String, suggestions: [String] = [], candidates: [MatchSummary] = [])
    case filteredByElementType(kind: String, value: String, elementType: String, roles: [UIRole], candidates: [MatchSummary] = [])
    case offScreen(selector: String, frames: [UIFrame], viewport: UIFrame)
    case multipleMatches(count: Int, kind: String, value: String, hasUniqueIDs: Bool, candidates: [MatchSummary] = [], onScreenOnly: Bool = false, offScreenIgnored: Int = 0)
    case invalidFrame(reason: String)
    case multipleSwitchDescendants(count: Int, selectorDescription: String)
    case nthOutOfRange(selector: String, nth: Int, count: Int)

    static let maxListed = 5

    var errorDescription: String? {
        let tip = AccessibilityTargetResolver.describeUITip
        switch self {
        case .notFound(let kind, let value, let suggestions, _):
            guard !suggestions.isEmpty else {
                return "No accessibility element matched \(kind) '\(value)'. \(tip)"
            }
            let quoted = suggestions.map { "'\(SelectorText.truncated($0))'" }
            return "No accessibility element matched \(kind) '\(value)'. Did you mean \(Self.alternatives(quoted))? \(tip)"
        case .filteredByElementType(let kind, let value, let elementType, let roles, _):
            let field = kind.hasPrefix("--") ? String(kind.dropFirst(2)) : kind
            let counted = roles.count == 1 ? "1 element has" : "\(roles.count) elements have"
            var distinctRoles: [String] = []
            for role in roles.map(\.rawValue) where !distinctRoles.contains(role) {
                distinctRoles.append(role)
            }
            return "No accessibility element matched \(kind) '\(value)' with --element-type \(elementType): \(counted) that \(field) (roles: \(distinctRoles.joined(separator: ", "))). \(tip)"
        case .offScreen(let selector, let frames, let viewport):
            let advice = "Scroll it into view or open the screen that shows it, wait with --wait-timeout, or pass --allow-offscreen to tap it anyway."
            if frames.count == 1 {
                return "Matched \(selector) is off screen: its frame \(frames[0].summary) is outside the \(viewport.sizeSummary) screen, for example on a hidden sheet or below the fold. \(advice) \(tip)"
            }
            let listed = Self.listed(frames.map(\.summary), separator: ", ")
            return "All \(frames.count) matches for \(selector) are off screen: \(listed) (the screen is \(viewport.sizeSummary)), for example on a hidden sheet or below the fold. \(advice) \(tip)"
        case .multipleMatches(let count, let kind, let value, let hasUniqueIDs, let candidates, let onScreenOnly, let offScreenIgnored):
            var head = "Multiple (\(count)) accessibility elements matched \(kind) '\(value)'"
            if onScreenOnly { head += " on screen" }
            if !candidates.isEmpty {
                head += ": " + Self.listed(candidates.map(\.text), separator: "; ", total: count)
            }
            if offScreenIgnored > 0 { head += " (\(offScreenIgnored) more off screen ignored)" }
            if kind == "--id" {
                return "\(head). The id is not unique on this screen: narrow with --element-type, or tap one by coordinates (tap -x/-y) using the frames above. \(tip)"
            }
            if hasUniqueIDs {
                return "\(head). Use --id when labels are not unique. \(tip)"
            }
            return "\(head), and none of the matches expose an id on this screen. Use coordinates for this step (tap -x/-y) or target a more specific screen/state. \(tip)"
        case .invalidFrame(let reason):
            return "\(reason) \(tip)"
        case .nthOutOfRange(let selector, let nth, let count):
            return "--nth \(nth) asked for match \(nth) of \(selector), but there \(count == 1 ? "is 1 match" : "are \(count) matches") on screen. \(tip)"
        case .multipleSwitchDescendants(let count, let selectorDescription):
            return "Matched element for \(selectorDescription) contains multiple (\(count)) switch/toggle controls. Target the switch more specifically with --id when available, or use coordinates. Use --element-type only when describe-ui reports a specific role or type, such as switch or Toggle. \(tip)"
        }
    }

    /// Missing, filtered out or off screen: a later tree may show the element, so `--wait-timeout` polls again.
    var isRetryable: Bool {
        switch self {
        case .notFound, .filteredByElementType, .offScreen, .nthOutOfRange:
            return true
        case .multipleMatches, .invalidFrame, .multipleSwitchDescendants:
            return false
        }
    }

    var isOffScreen: Bool {
        if case .offScreen = self { return true }
        return false
    }

    var userFacingDescription: String {
        errorDescription ?? "Offsider could not resolve the requested accessibility element."
    }

    var reason: FailureReason {
        switch self {
        case .notFound, .nthOutOfRange: return .selectorNotFound
        case .filteredByElementType: return .selectorFilteredByType
        case .offScreen: return .targetOffScreen
        case .multipleMatches: return .selectorAmbiguous
        case .multipleSwitchDescendants: return .selectorAmbiguousSwitch
        case .invalidFrame: return .targetHasNoFrame
        }
    }

    var failureMessage: String { userFacingDescription }

    var hint: String? { "offsider describe-ui --device <DEVICE_ID> --summary" }

    var candidates: [FailureCandidate] {
        switch self {
        case .notFound(_, _, _, let candidates), .filteredByElementType(_, _, _, _, let candidates),
             .multipleMatches(_, _, _, _, let candidates, _, _):
            return candidates.prefix(Self.maxListed).map(\.failureCandidate)
        case .offScreen, .invalidFrame, .multipleSwitchDescendants, .nthOutOfRange:
            return []
        }
    }

    private static func listed(_ items: [String], separator: String, total: Int? = nil) -> String {
        let total = total ?? items.count
        let shown = items.prefix(maxListed).joined(separator: separator)
        let hidden = total - min(items.count, maxListed)
        return hidden > 0 ? "\(shown), and \(hidden) more" : shown
    }

    private static func alternatives(_ items: [String]) -> String {
        guard items.count > 1 else { return items.first ?? "" }
        return items.dropLast().joined(separator: ", ") + " or " + items[items.count - 1]
    }
}

struct AccessibilityMatch {
    let element: UINode
    let selectorDescription: String
    let applicationFrame: UIFrame?
}

/// Every element a selector matched, and which of them are on screen.
struct SelectorCandidates {
    let matches: [UINode]
    /// Matches whose frame overlaps the viewport; every match when there is no viewport.
    let onScreen: [UINode]
    let viewport: UIFrame?
    /// True when only the folded comparison (quotes, spaces, invisible marks) found the matches.
    let folded: Bool
}

struct AccessibilityTargetResolver {
    static let describeUITip = "Make sure the app is on the expected screen, then run `offsider describe-ui --device <DEVICE_ID>` and prefer --id when available."

    private static let wideSwitchActivationWidthThreshold = 100.0
    private static let switchTrailingActivationInset = 31.0

    static func resolveTapPoint(
        roots: [UINode],
        query: AccessibilityQuery,
        elementType: String? = nil,
        allowOffscreen: Bool = false
    ) throws -> (x: Double, y: Double) {
        try resolveTap(roots: roots, query: query, elementType: elementType, allowOffscreen: allowOffscreen).point
    }

    static func candidates(
        roots: [UINode],
        query: AccessibilityQuery,
        elementType: String?
    ) -> SelectorCandidates {
        var elements = roots.flatMap { $0.flattened() }
        if let elementType {
            elements = elements.filter { $0.matches(elementType: elementType) }
        }

        var matches = exactMatches(in: elements, query: query)
        var folded = false
        if matches.isEmpty, query.allowsFolding {
            let target = SelectorText.folded(query.rawValue)
            if !target.isEmpty {
                matches = elements.filter { node in
                    query.field(of: node).map { SelectorText.folded($0) == target } ?? false
                }
                folded = !matches.isEmpty
            }
        }

        let viewport = UITree.viewport(in: roots)
        let onScreen = viewport.map { viewport in matches.filter { $0.frame?.isVisible(in: viewport) == true } } ?? matches
        return SelectorCandidates(matches: matches, onScreen: onScreen, viewport: viewport, folded: folded)
    }

    static func resolveElement(
        roots: [UINode],
        query: AccessibilityQuery,
        elementType: String? = nil,
        allowOffscreen: Bool = false,
        explainFailures: Bool = true,
        pick: MatchPick? = nil,
        logger: OffsiderLogger? = nil
    ) throws -> AccessibilityMatch {
        let found = candidates(roots: roots, query: query, elementType: elementType)
        guard !found.matches.isEmpty else {
            guard explainFailures else {
                throw ElementResolutionError.notFound(kind: query.kind, value: query.rawValue)
            }
            throw notFoundError(roots: roots, query: query, elementType: elementType, viewport: found.viewport)
        }

        let pool: [UINode]
        if !allowOffscreen, let viewport = found.viewport {
            // A match with no usable frame stays in, so the invalid frame error still names it.
            pool = found.matches.filter { node in
                guard node.hasPositiveFrame, let frame = node.frame else { return true }
                return frame.isVisible(in: viewport)
            }
            guard !pool.isEmpty else {
                throw ElementResolutionError.offScreen(
                    selector: query.selectorDescription,
                    frames: found.matches.compactMap(\.frame),
                    viewport: viewport
                )
            }
        } else {
            pool = found.matches
        }

        let ambiguity = Ambiguity(
            query: query,
            viewport: found.viewport,
            onScreenOnly: !allowOffscreen && found.viewport != nil,
            offScreenIgnored: found.matches.count - pool.count,
            pool: pool,
            roots: roots
        )
        let element: UINode
        switch (pick, query) {
        case (.nth(let nth)?, _):
            guard nth >= 1, nth <= pool.count else {
                throw ElementResolutionError.nthOutOfRange(selector: query.selectorDescription, nth: nth, count: pool.count)
            }
            element = pool[nth - 1]
        case (.last?, _):
            element = pool[pool.count - 1]
        case (nil, .id):
            element = try selectUniqueMatch(pool, ambiguity)
        case (nil, .label), (nil, .value):
            element = try selectBestLabelMatch(pool, ambiguity)
        }

        if found.folded, let logger {
            logger.info().log("Matched \(query.selectorDescription) after folding quotes and spaces (describe-ui shows '\(query.field(of: element) ?? "")')")
        }

        return AccessibilityMatch(
            element: element,
            selectorDescription: query.selectorDescription,
            applicationFrame: UITree.applicationFrame(in: roots)
        )
    }

    static func resolveTap(
        roots: [UINode],
        query: AccessibilityQuery,
        elementType: String? = nil,
        allowOffscreen: Bool = false,
        explainFailures: Bool = true,
        pick: MatchPick? = nil,
        logger: OffsiderLogger? = nil
    ) throws -> TapResolution {
        let match = try resolveElement(
            roots: roots, query: query, elementType: elementType, allowOffscreen: allowOffscreen, explainFailures: explainFailures, pick: pick, logger: logger
        )

        let activationElement = try selectActivationElement(
            from: match.element,
            roots: roots,
            selectorDescription: match.selectorDescription,
            allowSiblingRedirection: query.allowsSiblingRedirection
        )

        guard let frame = activationElement.frame else {
            throw ElementResolutionError.invalidFrame(reason: "Matched element has no frame.")
        }
        guard frame.width > 0, frame.height > 0 else {
            throw ElementResolutionError.invalidFrame(reason: "Matched element has an invalid frame size (\(frame.width)x\(frame.height)).")
        }

        var point = activationPoint(for: activationElement, frame: frame)
        if !allowOffscreen, let viewport = UITree.viewport(in: roots), !viewport.contains(UIPoint(x: point.x, y: point.y)) {
            guard frame.isVisible(in: viewport), let visible = frame.intersection(viewport) else {
                throw ElementResolutionError.offScreen(selector: match.selectorDescription, frames: [frame], viewport: viewport)
            }
            point = (x: visible.center.x, y: visible.center.y)
        }

        var candidates: [UINode] = []
        var stack: ScreenStack?
        if !allowOffscreen, let viewport = UITree.viewport(in: roots) {
            candidates = coverCandidates(of: activationElement, matched: match.element, at: UIPoint(x: point.x, y: point.y), viewport: viewport, roots: roots)
            if !candidates.isEmpty {
                let built = ScreenStack.build(roots: roots, viewport: viewport)
                candidates = onTopCandidates(candidates, over: activationElement, roots: roots, stack: built)
                stack = built
            }
        }
        return TapResolution(
            point: point,
            isSwitchLikeControl: activationElement.isSwitch,
            target: activationElement,
            matched: match.element,
            coverCandidates: candidates,
            stack: stack
        )
    }

    /// Drops candidates on a screen beneath a page, and on Android those its drawing order puts below the target.
    static func onTopCandidates(_ candidates: [UINode], over target: UINode, roots: [UINode], stack: ScreenStack) -> [UINode] {
        candidates.filter { candidate in
            guard !stack.isBeneath(candidate, in: roots) else { return false }
            guard candidate.isAndroid, let order = UITree.zOrder(of: candidate, over: target, in: roots), order.byDrawingOrder else { return true }
            return order.isAbove
        }
    }

    /// Plausible occluders whose frame holds `point`; tree order is not z-order on either platform, so a real hit-test must confirm one.
    /// On Android a node in a lower window (the app beneath a keyboard) or not visible to the user cannot cover the target;
    /// Android sorts siblings by position, not drawing order, so a sibling listed first may still be drawn on top.
    static func coverCandidates(of target: UINode, matched: UINode, at point: UIPoint, viewport: UIFrame, roots: [UINode]) -> [UINode] {
        let related = family(of: target, in: roots) + family(of: matched, in: roots)
        let android = target.isAndroid
        let targetRoot = roots.firstIndex { root in root.flattened().contains { $0.isSameElement(as: target) || $0.isSameElement(as: matched) } } ?? 0
        var found: [UINode] = []
        func visit(_ node: UINode, root: Int, underKeyboard: Bool) {
            let underKeyboard = underKeyboard || node.role == .keyboard
            let beneath = android && (root < targetRoot || node.androidVisibleToUser == false)
            if !beneath, let frame = coverArea(of: node, in: viewport), frame.contains(point), frame.isVisible(in: viewport),
               isPlausibleOccluder(node, underKeyboard: underKeyboard),
               !related.contains(where: { $0.isSameElement(as: node) }) {
                found.append(node)
            }
            for child in node.children {
                visit(child, root: root, underKeyboard: underKeyboard)
            }
        }
        for (index, root) in roots.enumerated() {
            visit(root, root: index, underKeyboard: false)
        }
        return found
    }

    /// The node's frame, or for a LogBox toast the strip beneath it that its unlisted touch container swallows.
    private static func coverArea(of node: UINode, in viewport: UIFrame) -> UIFrame? {
        guard let frame = node.frame else { return nil }
        return KnownOverlays.logBoxToast(node, viewport: viewport) != nil ? KnownOverlays.logBoxTouchArea(of: frame, in: viewport) : frame
    }

    /// The cover once a hit-test at the tap point found `hit`: nil when the hit is the target or its kin.
    /// Without a hit, the first candidate not lying wholly inside the target, which is more likely underneath it,
    /// and not a backdrop such as a sheet's scrim, which sits behind the content it surrounds.
    static func confirmedCover(hit: UINode?, resolution: TapResolution, roots: [UINode]) -> UINode? {
        guard !resolution.coverCandidates.isEmpty else {
            return nil
        }
        guard let hit else {
            let targetFrame = resolution.target?.frame
            let viewport = UITree.viewport(in: roots)
            return resolution.coverCandidates.first { candidate in
                guard let frame = candidate.frame else { return true }
                if let viewport, isBackdrop(frame, in: viewport) { return false }
                guard let targetFrame else { return true }
                return !targetFrame.encloses(frame)
            }
        }
        let related = [resolution.target, resolution.matched].compactMap { $0 }.flatMap { family(of: $0, in: roots) }
        if related.contains(where: { $0.isSameElement(as: hit) || $0.isSameTarget(as: hit) }) {
            return nil
        }
        // A node drawn wholly inside the target is its own content, such as a control's text listed as a sibling.
        if let targetFrame = resolution.target?.frame, let hitFrame = hit.frame, targetFrame.encloses(hitFrame) {
            return nil
        }
        if resolution.coverCandidates.contains(where: { $0.isSameTarget(as: hit) }) {
            return hit
        }
        return isPlausibleOccluder(hit, underKeyboard: hit.role == .keyboard) ? hit : nil
    }

    /// The keyboard over the tap point, from the tree already read; on Android its window's bounds decide, as its root view spans the screen.
    static func keyboardCover(_ resolution: TapResolution, in tree: UITree) -> UINode? {
        let roots = tree.roots
        let targets = [resolution.target, resolution.matched].compactMap { $0 }
        guard !targets.isEmpty, !targets.contains(where: { isUnderKeyboard($0, in: roots) }) else {
            return nil
        }
        let keyboardCandidates = resolution.coverCandidates.filter { isUnderKeyboard($0, in: roots) }
        if let touchAreas = keyboardTouchAreas(in: tree) {
            let point = UIPoint(x: resolution.point.x, y: resolution.point.y)
            guard touchAreas.contains(where: { $0.contains(point) }) else { return nil }
            return keyboardCandidates.last ?? roots.first { $0.role == .keyboard }
        }
        let viewport = UITree.viewport(in: roots)
        let targetFrame = resolution.target?.frame
        return keyboardCandidates.first { candidate in
            guard let frame = candidate.frame else { return false }
            if let viewport, isBackdrop(frame, in: viewport) { return false }
            return targetFrame.map { !$0.encloses(frame) } ?? true
        }
    }

    /// Where Android's input method windows take touches: their bounds around the keyboard's own nodes; nil on iOS and when no window bounds were read.
    private static func keyboardTouchAreas(in tree: UITree) -> [UIFrame]? {
        guard tree.platform == .android, let windows = tree.windows else { return nil }
        let areas = windows.filter { $0.kind == "inputMethod" }.compactMap(\.bounds).filter { $0.width > 0 && $0.height > 0 }
        guard !areas.isEmpty else { return nil }
        guard let viewport = UITree.viewport(in: tree.roots), let keys = keyArea(in: tree.roots, viewport: viewport) else { return areas }
        return areas.compactMap { $0.intersection(keys) }
    }

    /// The box around a keyboard's nodes smaller than a backdrop, since a floating keyboard's window and root view span the screen around its strip of keys.
    private static func keyArea(in roots: [UINode], viewport: UIFrame) -> UIFrame? {
        let frames = roots.filter { $0.role == .keyboard }.flatMap { $0.flattened() }.compactMap(\.frame)
            .filter { $0.width > 0 && $0.height > 0 && !isBackdrop($0, in: viewport) }
        guard let first = frames.first else { return nil }
        return frames.dropFirst().reduce(first) { box, frame in
            let left = min(box.x, frame.x), top = min(box.y, frame.y)
            return UIFrame(x: left, y: top, width: max(box.x + box.width, frame.x + frame.width) - left, height: max(box.y + box.height, frame.y + frame.height) - top)
        }
    }

    /// Covers at least 80 percent of the viewport, as a modal backdrop or scrim does; a banner covers far less.
    static func isBackdrop(_ frame: UIFrame, in viewport: UIFrame) -> Bool {
        guard let visible = frame.intersection(viewport), viewport.width > 0, viewport.height > 0 else { return false }
        return visible.width * visible.height >= 0.8 * viewport.width * viewport.height
    }

    /// True when `hit` is `element`, one of its ancestors or one of its descendants.
    static func isFamily(_ hit: UINode, of element: UINode, in roots: [UINode]) -> Bool {
        family(of: element, in: roots).contains { $0.isSameElement(as: hit) || $0.isSameTarget(as: hit) }
    }

    /// True when `node` is a keyboard or sits inside one.
    static func isUnderKeyboard(_ node: UINode, in roots: [UINode]) -> Bool {
        node.role == .keyboard || ancestors(of: node, in: roots).contains { $0.role == .keyboard }
    }

    /// `element` with its ancestors and descendants, none of which can cover it.
    private static func family(of element: UINode, in roots: [UINode]) -> [UINode] {
        ancestors(of: element, in: roots) + element.flattened()
    }

    private static let containerRoles: Set<UIRole> = [.window, .application, .scrollView, .list]

    /// Unlabelled groups never count: they wrap content rather than draw over it. A labelled one can be a banner on Android.
    private static func isPlausibleOccluder(_ node: UINode, underKeyboard: Bool) -> Bool {
        if node.role.isActionable || underKeyboard {
            return true
        }
        return node.normalizedLabel != nil && !containerRoles.contains(node.role)
    }

    static func ancestorsOf(_ element: UINode, in roots: [UINode]) -> [UINode] {
        ancestors(of: element, in: roots)
    }

    private static func ancestors(of element: UINode, in roots: [UINode]) -> [UINode] {
        for root in roots {
            if let path = path(to: element, from: root) {
                return Array(path.dropLast())
            }
        }
        return []
    }

    private static func path(to element: UINode, from node: UINode) -> [UINode]? {
        if node.isSameElement(as: element) {
            return [node]
        }
        for child in node.children {
            if let path = path(to: element, from: child) {
                return [node] + path
            }
        }
        return nil
    }

    private static func exactMatches(in elements: [UINode], query: AccessibilityQuery) -> [UINode] {
        let value = query.rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        var matches = elements.filter { query.field(of: $0) == value }
        if case .id = query, matches.isEmpty, !value.isEmpty {
            // Native Android ids are `package:id/name`; `--id name` finds them when nothing matches exactly.
            matches = elements.filter { $0.normalizedID?.hasSuffix(":id/" + value) == true }
        }
        return matches
    }

    /// Explains a miss: matches that `--element-type` removed, else the closest values of the same field.
    private static func notFoundError(
        roots: [UINode],
        query: AccessibilityQuery,
        elementType: String?,
        viewport: UIFrame?
    ) -> ElementResolutionError {
        if let elementType {
            let untyped = candidates(roots: roots, query: query, elementType: nil)
            if !untyped.matches.isEmpty {
                return .filteredByElementType(
                    kind: query.kind,
                    value: query.rawValue,
                    elementType: elementType,
                    roles: untyped.matches.map(\.role),
                    candidates: untyped.matches.prefix(ElementResolutionError.maxListed).map { MatchSummary($0, viewport: viewport) }
                )
            }
        }

        let elements = roots.flatMap { $0.flattened() }
        let onScreen = elements.filter { node in viewport.map { node.frame?.isVisible(in: $0) == true } ?? true }
        let offScreen = elements.filter { node in viewport.map { node.frame?.isVisible(in: $0) != true } ?? false }
        let ordered = onScreen + offScreen
        let suggestions = SelectorText.suggestions(for: query.rawValue, among: ordered.compactMap { query.field(of: $0) })
        let behind = suggestions.compactMap { suggestion in ordered.first { query.field(of: $0) == suggestion } }
        return .notFound(
            kind: query.kind,
            value: query.rawValue,
            suggestions: suggestions,
            candidates: behind.map { MatchSummary($0, viewport: viewport) }
        )
    }

    private static func activationPoint(
        for element: UINode,
        frame: UIFrame
    ) -> (x: Double, y: Double) {
        let centerY = frame.y + (frame.height / 2.0)

        if element.isSwitch, frame.width > wideSwitchActivationWidthThreshold {
            return (x: frame.x + frame.width - switchTrailingActivationInset, y: centerY)
        }

        return (x: frame.x + (frame.width / 2.0), y: centerY)
    }

    /// What an ambiguous match error needs to describe its candidates.
    private struct Ambiguity {
        let query: AccessibilityQuery
        let viewport: UIFrame?
        let onScreenOnly: Bool
        let offScreenIgnored: Int
        /// Every match `--nth` counts, in tree order, and the tree it came from.
        var pool: [UINode] = []
        var roots: [UINode] = []

        func summary(_ node: UINode, stack: ScreenStack) -> MatchSummary {
            let index = pool.firstIndex { $0.isSameElement(as: node) }.map { $0 + 1 }
            return MatchSummary(node, viewport: viewport, index: index, roots: roots, stack: stack)
        }
    }

    private static func selectUniqueMatch(
        _ matches: [UINode],
        _ ambiguity: Ambiguity
    ) throws -> UINode {
        guard !matches.isEmpty else {
            throw ElementResolutionError.notFound(kind: ambiguity.query.kind, value: ambiguity.query.rawValue)
        }
        guard matches.count == 1 else {
            let stack = ScreenStack.build(roots: ambiguity.roots, viewport: ambiguity.viewport)
            if let chosen = stackedPick(matches, roots: ambiguity.roots, stack: stack) {
                return chosen
            }
            let hasUniqueIDs = matches.contains {
                $0.normalizedID != nil
            }
            let summaries = matches.prefix(ElementResolutionError.maxListed).map { ambiguity.summary($0, stack: stack) }
            throw ElementResolutionError.multipleMatches(
                count: matches.count,
                kind: ambiguity.query.kind,
                value: ambiguity.query.rawValue,
                hasUniqueIDs: hasUniqueIDs,
                candidates: Array(summaries),
                onScreenOnly: ambiguity.onScreenOnly,
                offScreenIgnored: ambiguity.offScreenIgnored
            )
        }
        return matches[0]
    }

    /// Among several matches, the only one not beneath a page; else, when they all share one activation point, the one a touch there reaches.
    static func stackedPick(_ matches: [UINode], roots: [UINode], stack: ScreenStack) -> UINode? {
        let uncovered = matches.filter { !stack.isBeneath($0, in: roots) }
        if uncovered.count == 1 {
            return uncovered[0]
        }
        let pool = uncovered.isEmpty ? matches : uncovered
        let points = pool.compactMap { node in node.frame.map { activationPoint(for: node, frame: $0) } }
        guard points.count == pool.count, let first = points.first, points.allSatisfy({ point in
            abs(point.x - first.x) <= TransitionGuard.frameTolerance && abs(point.y - first.y) <= TransitionGuard.frameTolerance
        }) else {
            return nil
        }
        let chain = UITree.hitChain(in: roots, at: UIPoint(x: first.x, y: first.y))
        return pool.first { match in chain.contains { $0.isSameElement(as: match) } } ?? pool.last
    }

    private static func selectBestLabelMatch(
        _ matches: [UINode],
        _ ambiguity: Ambiguity
    ) throws -> UINode {
        let switchLikeMatches = matches.filter(\.isSwitch)
        if switchLikeMatches.count == 1 {
            return switchLikeMatches[0]
        }
        if switchLikeMatches.count > 1 {
            return try selectUniqueMatch(switchLikeMatches, ambiguity)
        }

        let actionableMatches = matches.filter(\.role.isActionable)
        if actionableMatches.count == 1 {
            return actionableMatches[0]
        }

        if actionableMatches.count > 1 {
            return try selectUniqueMatch(actionableMatches, ambiguity)
        }

        return try selectUniqueMatch(matches, ambiguity)
    }

    private static func selectActivationElement(
        from matchedElement: UINode,
        roots: [UINode],
        selectorDescription: String,
        allowSiblingRedirection: Bool
    ) throws -> UINode {
        if matchedElement.isSwitch {
            return matchedElement
        }

        let switchDescendants = matchedElement.flattened().filter(\.isSwitch)
        if !switchDescendants.isEmpty {
            guard switchDescendants.count == 1 else {
                throw ElementResolutionError.multipleSwitchDescendants(
                    count: switchDescendants.count,
                    selectorDescription: selectorDescription
                )
            }
            return switchDescendants[0]
        }

        if matchedElement.role.isActionable {
            return matchedElement
        }

        if allowSiblingRedirection, let ancestor = nearestAncestor(of: matchedElement, in: roots) {
            let siblingSwitches = directSwitchLikeChildren(of: ancestor)
            if siblingSwitches.count == 1 {
                return siblingSwitches[0]
            }
        }

        return matchedElement
    }

    private static func directSwitchLikeChildren(of element: UINode) -> [UINode] {
        element.children.filter(\.isSwitch)
    }

    private static func nearestAncestor(
        of matchedElement: UINode,
        in roots: [UINode]
    ) -> UINode? {
        for root in roots {
            if let ancestor = nearestAncestor(of: matchedElement, in: root, parent: nil) {
                return ancestor
            }
        }
        return nil
    }

    private static func nearestAncestor(
        of matchedElement: UINode,
        in currentElement: UINode,
        parent: UINode?
    ) -> UINode? {
        if currentElement.isSameElement(as: matchedElement) {
            return parent
        }

        for child in currentElement.children {
            if let ancestor = nearestAncestor(of: matchedElement, in: child, parent: currentElement) {
                return ancestor
            }
        }
        return nil
    }
}

extension UINode {
    var normalizedID: String? { Self.trimmed(id) }
    var normalizedLabel: String? { Self.trimmed(label) }
    var normalizedValue: String? { Self.trimmed(value) }
    var isSwitch: Bool { role == .switch }
    var isSlider: Bool { role == .slider }

    /// A hit-test reads the element afresh, so only the fields a separate read keeps stable identify it.
    func isSameTarget(as other: UINode) -> Bool {
        role == other.role && id == other.id && label == other.label && frame == other.frame
    }

    /// A frame with a positive size, the only kind that can be judged on or off screen.
    var hasPositiveFrame: Bool {
        guard let frame else { return false }
        return frame.width > 0 && frame.height > 0
    }

    /// `--element-type` matches the neutral role in any case, or the native type name exactly.
    func matches(elementType: String) -> Bool {
        role.rawValue.caseInsensitiveCompare(elementType) == .orderedSame || native.typeName == elementType
    }

    private static func trimmed(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}

extension UIFrame {
    func encloses(_ other: UIFrame) -> Bool {
        other.x >= x && other.y >= y && other.x + other.width <= x + width && other.y + other.height <= y + height
    }
}

extension UINode {
    var isAndroid: Bool {
        if case .android = native { return true }
        return false
    }

    var androidVisibleToUser: Bool? {
        if case .android(let attributes) = native { return attributes.visibleToUser }
        return nil
    }
}
