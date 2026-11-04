import Foundation
import OffsiderCore

indirect enum AccessibilityQuery {
    case id(String)
    case label(String)
    /// The folded label holds the folded text anywhere, in the same case.
    case labelContains(String)
    case value(String)
    /// `--id` narrowed by `--label`, `--label-contains` and `--value`: an element must match every part.
    case all(AccessibilityQuery, refinedBy: [AccessibilityQuery])

    var allowsSiblingRedirection: Bool {
        switch self {
        case .label, .labelContains:
            return true
        case .id, .value:
            return false
        case .all(let primary, _):
            return primary.allowsSiblingRedirection
        }
    }

    /// Labels and values match after folding quotes and spaces; ids stay exact, and `--label-contains` always folds.
    var allowsFolding: Bool {
        switch self {
        case .label, .value:
            return true
        case .id, .labelContains, .all:
            return false
        }
    }

    var kind: String {
        switch self {
        case .id: return "--id"
        case .label: return "--label"
        case .labelContains: return "--label-contains"
        case .value: return "--value"
        case .all(let primary, _): return primary.kind
        }
    }

    var rawValue: String {
        switch self {
        case .id(let value), .label(let value), .labelContains(let value), .value(let value):
            return value
        case .all(let primary, _):
            return primary.rawValue
        }
    }

    var selectorDescription: String {
        guard case .all(let primary, let refinements) = self else {
            return "\(kind) '\(rawValue)'"
        }
        return ([primary] + refinements).map(\.selectorDescription).joined(separator: " ")
    }

    /// The selector as flags a shell takes back: `--id save --label 'Save all'`.
    var shellArguments: String {
        guard case .all(let primary, let refinements) = self else {
            return "\(kind) \(VerifyOutput.shellWord(rawValue))"
        }
        return ([primary] + refinements).map(\.shellArguments).joined(separator: " ")
    }

    /// The trimmed field this query reads from `node`.
    func field(of node: UINode) -> String? {
        switch self {
        case .id: return node.normalizedID
        case .label, .labelContains: return node.normalizedLabel
        case .value: return node.isSecure ? nil : node.normalizedValue
        case .all(let primary, _): return primary.field(of: node)
        }
    }

    /// True when the node's field equals the text exactly after trimming, or after folding quotes and spaces; `--label-contains` wants it anywhere in the folded label.
    func matches(_ node: UINode) -> Bool {
        guard let field = field(of: node) else { return false }
        let wanted = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if case .labelContains = self {
            return SelectorText.folded(field, contains: wanted)
        }
        return field == wanted || (allowsFolding && SelectorText.folded(field) == SelectorText.folded(wanted))
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
    /// How close it came to a selector that matched nothing.
    var closeness: SelectorText.Closeness? = nil

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
            label: Self.shownLabel(of: node).map { SelectorText.truncated($0) },
            frame: node.frame,
            isOnScreen: viewport.map { node.frame?.isVisible(in: $0) == true }
        )
        self.index = index
        let ancestors = AccessibilityTargetResolver.ancestorsOf(node, in: roots)
        window = ancestors.first.flatMap(Self.shownLabel).map { SelectorText.truncated($0) }
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

    /// The trimmed label as tree output shows it, so a message never names what `describe-ui` hides.
    static func shownLabel(of node: UINode) -> String? {
        node.normalizedLabel.map { OutputMasks.current.mask.shownLabel($0, id: node.normalizedID) }
    }

    var text: String {
        var parts = [role.rawValue]
        if let id { parts.append("id=\(TerminalText.field(id))") }
        if let label { parts.append("label=\(TerminalText.quoted(label))") }
        parts.append(frame?.summary ?? "with no frame")
        if isOnScreen == false { parts.append("off screen") }
        if let screen { parts.append("in screen=\(TerminalText.field(screen))") }
        if beneath == true { parts.append("(beneath another screen)") }
        if let index { parts.append("(--nth \(index))") }
        return parts.joined(separator: " ")
    }

    var failureCandidate: FailureCandidate {
        FailureCandidate(id: id, label: label, role: role.rawValue, frame: frame, onScreen: isOnScreen, index: index, window: window, screen: screen, beneath: beneath, closeness: closeness)
    }
}

/// How a near miss is told: its relation to the text asked for, and the selector that would match it.
enum NearMissPhrase {
    /// ` (starts with your text; --label-contains matches it)` after a suggestion that holds the text; empty for others.
    static func annotation(_ near: SelectorText.NearMatch, kind: String, query: String) -> String {
        guard let relation = holding(near.closeness) else { return "" }
        guard isLabel(kind), let contained = SelectorText.containedText(of: query, in: near.text) else {
            return " (\(relation) your text)"
        }
        let selector = contained == SelectorText.folded(query) ? "--label-contains" : "--label-contains \(TerminalText.quoted(contained))"
        return " (\(relation) your text; \(selector) matches it)"
    }

    /// `starts with it, use --label-contains 'Choose a'`, or `is close, use --label 'Settings'`.
    static func relation(_ near: SelectorText.NearMatch, kind: String, query: String) -> String {
        let said: String
        switch near.closeness {
        case .case: said = "differs only in case"
        case .prefix: said = "starts with it"
        case .contains: said = "contains it"
        case .similar: said = "is close"
        }
        if holding(near.closeness) != nil, isLabel(kind),
           let contained = SelectorText.containedText(of: query, in: near.text) {
            return "\(said), use --label-contains \(TerminalText.quoted(contained))"
        }
        return "\(said), use \(kind == "--label-contains" ? "--label" : kind) \(TerminalText.quoted(near.text))"
    }

    private static func isLabel(_ kind: String) -> Bool {
        kind == "--label" || kind == "--label-contains"
    }

    private static func holding(_ closeness: SelectorText.Closeness) -> String? {
        switch closeness {
        case .prefix: "starts with"
        case .contains: "contains"
        case .case, .similar: nil
        }
    }
}

enum ElementResolutionError: LocalizedError, UserFacingError, OffsiderFailure {
    /// `candidates` are the elements behind `suggestions`.
    case notFound(kind: String, value: String, suggestions: [SelectorText.NearMatch] = [], candidates: [MatchSummary] = [])
    case filteredByElementType(kind: String, value: String, elementType: String, roles: [UIRole], candidates: [MatchSummary] = [])
    case offScreen(selector: String, frames: [UIFrame], viewport: UIFrame)
    /// On screen, but past an edge of the scroll view or list around it, where something outside it may take the tap.
    case beyondScrollView(selector: String, frame: UIFrame, visible: UIFrame, side: OffScreenSide)
    case multipleMatches(count: Int, kind: String, value: String, hasUniqueIDs: Bool, candidates: [MatchSummary] = [], onScreenOnly: Bool = false, offScreenIgnored: Int = 0)
    case invalidFrame(reason: String)
    case multipleSwitchDescendants(count: Int, selectorDescription: String)
    case nthOutOfRange(selector: String, nth: Int, count: Int)
    /// The `--id` matched, but no match had the `--label` or `--value` asked for too.
    case refinedOut(selector: String, candidates: [MatchSummary])
    /// The text is in LogBox toast `toast`, whose banner is not a separate element per line.
    case inLogBoxToast(kind: String, value: String, toast: Int)

    static let maxListed = 5

    var errorDescription: String? {
        let tip = AccessibilityTargetResolver.describeUITip
        switch self {
        case .notFound(let kind, let value, let suggestions, _):
            guard !suggestions.isEmpty else {
                return "No accessibility element matched \(kind) '\(value)'. \(tip)"
            }
            let quoted = suggestions.map { TerminalText.quoted(SelectorText.truncated($0.text)) + NearMissPhrase.annotation($0, kind: kind, query: value) }
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
        case .beyondScrollView(let selector, let frame, let visible, let side):
            return "Matched \(selector) is \(Self.place(side)); scroll first: its frame \(frame.summary) is outside the \(visible.summary) the scroll view shows, so a tap there would land on what lies outside it, such as a footer. Scroll it into view, wait with --wait-timeout, or pass --allow-offscreen to tap it anyway. \(tip)"
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
        case .refinedOut(let selector, let candidates):
            let listed = Self.listed(candidates.map(\.text), separator: "; ")
            return "No accessibility element matched \(selector): the id matches \(listed), with another label or value. \(tip)"
        case .inLogBoxToast(let kind, let value, let toast):
            return "No accessibility element matched \(kind) '\(value)', but LogBox toast \(toast) shows that text. Read the log with `offsider rn logbox open --index \(toast)`, or clear it with `offsider rn logbox dismiss --index \(toast)`."
        case .multipleSwitchDescendants(let count, let selectorDescription):
            return "Matched element for \(selectorDescription) contains multiple (\(count)) switch/toggle controls. Target the switch more specifically with --id when available, or use coordinates. Use --element-type only when describe-ui reports a specific role or type, such as switch or Toggle. \(tip)"
        }
    }

    /// Missing, filtered out or off screen: a later tree may show the element, so `--wait-timeout` polls again.
    var isRetryable: Bool {
        switch self {
        case .notFound, .filteredByElementType, .offScreen, .beyondScrollView, .nthOutOfRange, .refinedOut, .inLogBoxToast:
            return true
        case .multipleMatches, .invalidFrame, .multipleSwitchDescendants:
            return false
        }
    }

    var isOffScreen: Bool {
        switch self {
        case .offScreen, .beyondScrollView: return true
        default: return false
        }
    }

    var userFacingDescription: String {
        errorDescription ?? "Offsider could not resolve the requested accessibility element."
    }

    var reason: FailureReason {
        switch self {
        case .notFound, .nthOutOfRange, .refinedOut, .inLogBoxToast: return .selectorNotFound
        case .filteredByElementType: return .selectorFilteredByType
        case .offScreen, .beyondScrollView: return .targetOffScreen
        case .multipleMatches: return .selectorAmbiguous
        case .multipleSwitchDescendants: return .selectorAmbiguousSwitch
        case .invalidFrame: return .targetHasNoFrame
        }
    }

    var failureMessage: String { userFacingDescription }

    var hint: String? {
        if case .inLogBoxToast = self { return "offsider rn logbox status --device <DEVICE_ID>" }
        return "offsider describe-ui --device <DEVICE_ID> --summary"
    }

    var candidates: [FailureCandidate] {
        switch self {
        case .notFound(_, _, _, let candidates), .filteredByElementType(_, _, _, _, let candidates),
             .multipleMatches(_, _, _, _, let candidates, _, _), .refinedOut(_, let candidates):
            return candidates.prefix(Self.maxListed).map(\.failureCandidate)
        case .offScreen, .beyondScrollView, .invalidFrame, .multipleSwitchDescendants, .nthOutOfRange, .inLogBoxToast:
            return []
        }
    }

    /// `below the fold of its scroll view`, or the edge it lies past.
    private static func place(_ side: OffScreenSide) -> String {
        switch side {
        case .below: return "below the fold of its scroll view"
        case .above: return "above the top of its scroll view"
        case .left: return "past the left edge of its scroll view"
        case .right: return "past the right edge of its scroll view"
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
        if case .all(let primary, let refinements) = query {
            let found = candidates(roots: roots, query: primary, elementType: elementType)
            let refine = { (nodes: [UINode]) in nodes.filter { node in refinements.allSatisfy { $0.matches(node) } } }
            return SelectorCandidates(matches: refine(found.matches), onScreen: refine(found.onScreen), viewport: found.viewport, folded: false)
        }
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
        front: FrontReading? = nil,
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
            roots: roots,
            front: front
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
        case (nil, .id), (nil, .all):
            element = try selectUniqueMatch(pool, ambiguity)
        case (nil, .label), (nil, .labelContains), (nil, .value):
            element = try selectBestLabelMatch(pool, ambiguity)
        }

        if found.folded, let logger {
            logger.info().log("Matched \(query.selectorDescription) after folding quotes and spaces (describe-ui shows \(TerminalText.quoted(query.field(of: element) ?? "")))")
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
        front: FrontReading? = nil,
        logger: OffsiderLogger? = nil
    ) throws -> TapResolution {
        let match = try resolveElement(
            roots: roots, query: query, elementType: elementType, allowOffscreen: allowOffscreen, explainFailures: explainFailures, pick: pick, front: front, logger: logger
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
        if !allowOffscreen, let viewport = UITree.viewport(in: roots) {
            point = try visiblePoint(point, of: activationElement, frame: frame, viewport: viewport, roots: roots, selector: match.selectorDescription)
        }

        var candidates: [UINode] = []
        var stack: ScreenStack?
        if !allowOffscreen, let viewport = UITree.viewport(in: roots) {
            let tree = TreeIndex(roots: roots)
            candidates = coverCandidates(of: activationElement, matched: match.element, at: UIPoint(x: point.x, y: point.y), viewport: viewport, in: tree)
            if !candidates.isEmpty {
                let built = ScreenStack.build(tree, viewport: viewport)
                candidates = onTopCandidates(candidates, over: activationElement, in: tree, stack: built)
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

    /// The tap a selector on `element` itself would make, for the shared on-screen judgement: its own activation point, what may draw over it, and the pages; nil when no point of it shows.
    static func resolution(of element: UINode, roots: [UINode], viewport: UIFrame, stack: ScreenStack) -> TapResolution? {
        resolution(of: element, among: Occluders(TreeIndex(roots: roots), viewport: viewport), stack: stack)
    }

    /// `resolution(of:roots:viewport:stack:)` among a tree's possible occluders already read.
    static func resolution(of element: UINode, among occluders: Occluders, stack: ScreenStack) -> TapResolution? {
        let tree = occluders.tree, viewport = occluders.viewport
        guard let frame = element.frame, frame.width > 0, frame.height > 0,
              let point = try? visiblePoint(activationPoint(for: element, frame: frame), of: element, frame: frame, viewport: viewport, ancestors: tree.ancestors(of: element), selector: "") else {
            return nil
        }
        let candidates = coverCandidates(of: element, matched: element, at: UIPoint(x: point.x, y: point.y), among: occluders)
        return TapResolution(
            point: point,
            isSwitchLikeControl: element.isSwitch,
            target: element,
            matched: element,
            coverCandidates: candidates.isEmpty ? [] : onTopCandidates(candidates, over: element, in: tree, stack: stack),
            stack: stack
        )
    }

    /// A switch that toggles only at its trailing knob, not across its whole row.
    static func isWideSwitch(_ element: UINode, frame: UIFrame) -> Bool {
        element.isSwitch && frame.width > wideSwitchActivationWidthThreshold
    }

    /// Less than this much of an element showing on either axis inside its scroll view is too little to tap safely.
    static let minimumVisibleExtent = 8.0

    /// `point`, or when it lies outside them the centre of what the screen and the top and bottom of every scroll view or list around the element show of `frame`; too little showing is off screen.
    static func visiblePoint(
        _ point: (x: Double, y: Double), of element: UINode, frame: UIFrame, viewport: UIFrame, roots: [UINode], selector: String
    ) throws -> (x: Double, y: Double) {
        try visiblePoint(point, of: element, frame: frame, viewport: viewport, ancestors: ancestors(of: element, in: roots), selector: selector)
    }

    private static func visiblePoint(
        _ point: (x: Double, y: Double), of element: UINode, frame: UIFrame, viewport: UIFrame, ancestors: [UINode], selector: String
    ) throws -> (x: Double, y: Double) {
        let visible = try shownPart(of: element, frame: frame, viewport: viewport, ancestors: ancestors, selector: selector)
        if visible.contains(UIPoint(x: point.x, y: point.y)) {
            return point
        }
        return (x: visible.center.x, y: visible.center.y)
    }

    /// What the screen and the scroll views around the element show of `frame`; nil when too little does.
    static func visibleRegion(of element: UINode, frame: UIFrame, viewport: UIFrame, roots: [UINode]) -> UIFrame? {
        try? shownPart(of: element, frame: frame, viewport: viewport, ancestors: ancestors(of: element, in: roots), selector: "")
    }

    /// The side of its scroll view an element with too little showing lies past; nil when it shows.
    static func sidePastScrollView(of element: UINode, frame: UIFrame, viewport: UIFrame, in tree: TreeIndex) -> OffScreenSide? {
        do {
            _ = try shownPart(of: element, frame: frame, viewport: viewport, ancestors: tree.ancestors(of: element), selector: "")
            return nil
        } catch ElementResolutionError.beyondScrollView(_, _, _, let side) {
            return side
        } catch {
            return nil
        }
    }

    /// `resolution` moved to `point`, with what may draw over it there.
    static func resolution(of resolution: TapResolution, at point: UIPoint, roots: [UINode], viewport: UIFrame) -> TapResolution {
        var moved = TapResolution(
            point: (x: point.x, y: point.y), isSwitchLikeControl: resolution.isSwitchLikeControl,
            target: resolution.target, matched: resolution.matched, stack: resolution.stack
        )
        guard let target = resolution.target ?? resolution.matched else { return moved }
        let tree = TreeIndex(roots: roots)
        let candidates = coverCandidates(of: target, matched: resolution.matched ?? target, at: point, viewport: viewport, in: tree)
        let stack = resolution.stack ?? ScreenStack.build(tree, viewport: viewport)
        moved.coverCandidates = candidates.isEmpty ? [] : onTopCandidates(candidates, over: target, in: tree, stack: stack)
        moved.stack = stack
        return moved
    }

    private static func shownPart(of element: UINode, frame: UIFrame, viewport: UIFrame, ancestors: [UINode], selector: String) throws -> UIFrame {
        guard frame.isVisible(in: viewport), var visible = frame.intersection(viewport) else {
            throw ElementResolutionError.offScreen(selector: selector, frames: [frame], viewport: viewport)
        }
        let scrollRoles: Set<UIRole> = [.scrollView, .list]
        for ancestor in ancestors.reversed() where scrollRoles.contains(ancestor.role) && ancestor.hasPositiveFrame {
            guard let shown = ancestor.frame?.intersection(viewport) else { continue }
            // Only the top and bottom clip: a carousel may draw peeking cards past its sides.
            let band = UIFrame(x: visible.x, y: shown.y, width: visible.width, height: shown.height)
            let clipped = visible.intersection(band)
            if clipped == visible { continue }
            guard let clipped, clipped.height >= min(Self.minimumVisibleExtent, frame.height) else {
                throw ElementResolutionError.beyondScrollView(selector: selector, frame: frame, visible: shown, side: side(of: frame, past: band))
            }
            visible = clipped
        }
        return visible
    }

    /// The edge of `shown` that `frame` lies or reaches past.
    private static func side(of frame: UIFrame, past shown: UIFrame) -> OffScreenSide {
        if let side = OffScreenSide.of(frame, in: shown) { return side }
        if frame.y + frame.height > shown.y + shown.height { return .below }
        if frame.y < shown.y { return .above }
        return frame.x + frame.width > shown.x + shown.width ? .right : .left
    }

    /// Drops candidates on a screen beneath a page, and on Android those its drawing order puts below the target.
    static func onTopCandidates(_ candidates: [UINode], over target: UINode, in tree: TreeIndex, stack: ScreenStack) -> [UINode] {
        candidates.filter { candidate in
            guard !stack.isBeneath(candidate, in: tree) else { return false }
            guard candidate.isAndroid, let order = UITree.zOrder(of: candidate, over: target, in: tree), order.byDrawingOrder else { return true }
            return order.isAbove
        }
    }

    /// Plausible occluders whose frame holds `point`; tree order is not z-order on either platform, so a real hit-test must confirm one.
    /// On Android a node in a lower window (the app beneath a keyboard) or not visible to the user cannot cover the target;
    /// Android sorts siblings by position, not drawing order, so a sibling listed first may still be drawn on top. A scroll indicator takes no taps, so it is never one.
    static func coverCandidates(of target: UINode, matched: UINode, at point: UIPoint, viewport: UIFrame, in tree: TreeIndex) -> [UINode] {
        coverCandidates(of: target, matched: matched, at: point, among: Occluders(tree, viewport: viewport))
    }

    /// `coverCandidates(of:matched:at:viewport:in:)` among a tree's possible occluders already read.
    static func coverCandidates(of target: UINode, matched: UINode, at point: UIPoint, among occluders: Occluders) -> [UINode] {
        let tree = occluders.tree, roots = tree.roots, viewport = occluders.viewport
        let targetIndex = tree.firstIndex(of: target)
        let same = matched.isSameElement(as: target)
        let matchedIndex = same ? targetIndex : tree.firstIndex(of: matched)
        let path = targetIndex.map(tree.indexPath(to:))
        let matchedPath = matchedIndex.map(tree.indexPath(to:))
        // Each related node by the first node identical to it, so a node is related when any node identical to it is.
        var related = Set([targetIndex, matchedIndex].compactMap { $0 }.flatMap { tree.lineage(of: $0) }.compactMap(tree.firstIndex(at:)))
        related.formUnion((target.flattened() + (same ? [] : matched.flattened())).compactMap(tree.firstIndex(of:)))
        // Keys sit over the app, its own keypad's as much as the system's, so only another key can cover one.
        let targetIsKey = targetIndex.map(tree.isInKeyboard) ?? (target.role == .keyboard)
        let android = target.isAndroid
        let targetRoot = (path ?? matchedPath)?.first ?? 0
        // A simulator lists an app's windows, children of it that fill the screen, bottom first, so one listed before the target's is drawn beneath it.
        let simulator = target.iosPID != nil
        let targetWindow = (path ?? matchedPath).flatMap { path -> Int? in
            guard simulator, !android, path.count > 1, roots[path[0]].children.indices.contains(path[1]) else { return nil }
            return Occluders.isWindow(roots[path[0]].children[path[1]], of: roots[path[0]], viewport: viewport) ? path[1] : nil
        }
        // What lies inside an unlabelled container the target is, such as a tab bar listed beside its tabs, is its own content.
        let content = target.isActionable || target.normalizedLabel != nil ? nil : target.frame
        func reaches(_ node: UINode, _ place: Occluders.Place) -> Bool {
            guard let area = place.logBoxArea else {
                guard let frame = node.frame, frame.contains(point), frame.isVisible(in: viewport) else { return false }
                return place.band?.contains(point.y) ?? true
            }
            return area.contains(point) || CoverJudge.reaches(area, target.frame)
        }
        return occluders.near(point).compactMap { index -> UINode? in
            let node = tree.nodes[index]
            guard let place = occluders.place(of: index) else { return nil }
            let beneath = android ? place.root < targetRoot || node.androidVisibleToUser == false
                : simulator && place.root == targetRoot && place.window.map { window in targetWindow.map { window < $0 } ?? false } == true
            guard !beneath, !targetIsKey || place.underKeyboard, reaches(node, place),
                  place.occludes || CoverJudge.isBar(node, over: target, at: point, viewport: viewport),
                  !(content.map { content in node.frame.map { content.encloses($0, tolerance: TransitionGuard.frameTolerance) } ?? false } ?? false),
                  !(tree.firstIndex(at: index).map(related.contains) ?? false) else { return nil }
            return node
        }
    }

    /// What may draw over any point of one tree, read once for many points: each node that could, with the window, scroll views and keyboard around it, by the rows of the screen it spans.
    struct Occluders {
        let tree: TreeIndex
        let viewport: UIFrame
        /// By pre-order index; nil for a node that never covers, a scroll indicator or one off the screen.
        private let places: [Place?]
        /// Pre-order indexes by the row of the viewport their frame spans.
        private let rows: [[Int]]
        /// LogBox toasts, whose touch area any point may meet.
        private let anywhere: [Int]
        private let all: [Int]

        struct Place {
            let root: Int
            /// On a simulator, the application's screen-filling child holding the node.
            let window: Int?
            /// The top and bottom of the scroll views around the node: it shows only between them.
            let band: ClosedRange<Double>?
            let underKeyboard: Bool
            let occludes: Bool
            /// A LogBox toast's touch area; nil for anything else.
            let logBoxArea: UIFrame?
        }

        static let rowCount = 64

        init(_ tree: TreeIndex, viewport: UIFrame) {
            self.tree = tree
            self.viewport = viewport
            var places = [Place?](repeating: nil, count: tree.nodes.count)
            var rows = [[Int]](repeating: [], count: Self.rowCount)
            var anywhere: [Int] = [], all: [Int] = []
            var bands = [ClosedRange<Double>?](repeating: nil, count: tree.nodes.count)
            var windows = [Int?](repeating: nil, count: tree.nodes.count)
            for (index, node) in tree.nodes.enumerated() {
                let parent = tree.parent(of: index)
                if let parent {
                    let above = tree.nodes[parent]
                    var band = bands[parent]
                    // A scroll view or list shows its rows only between its top and bottom.
                    if [.scrollView, .list].contains(above.role), let frame = above.frame, above.hasPositiveFrame {
                        let top = max(band?.lowerBound ?? -.infinity, frame.y), bottom = min(band?.upperBound ?? .infinity, frame.y + frame.height)
                        band = top <= bottom ? top...bottom : frame.y...frame.y
                    }
                    bands[index] = band
                    windows[index] = tree.parent(of: parent) == nil && Self.isWindow(node, of: above, viewport: viewport) ? tree.indexPath(to: index).last : windows[parent]
                }
                let underKeyboard = tree.isInKeyboard(index)
                let occludes = isPlausibleOccluder(node, underKeyboard: underKeyboard)
                let logBoxArea = KnownOverlays.logBoxTouchArea(of: node, in: viewport)
                guard occludes || CoverJudge.isBar(node), !ScrollIndicator.isIndicator(node, parent: parent.map { tree.nodes[$0] }) else { continue }
                if logBoxArea != nil {
                    anywhere.append(index)
                } else if let frame = node.frame, frame.isVisible(in: viewport) {
                    let low = max(frame.y, viewport.y), high = min(frame.y + frame.height, viewport.y + viewport.height)
                    guard let first = Self.row(of: low, in: viewport), let last = Self.row(of: high, in: viewport) else { continue }
                    for row in first...last { rows[row].append(index) }
                } else {
                    continue
                }
                places[index] = Place(
                    root: tree.root(of: index), window: windows[index], band: bands[index], underKeyboard: underKeyboard, occludes: occludes, logBoxArea: logBoxArea
                )
                all.append(index)
            }
            self.places = places
            self.rows = rows
            self.anywhere = anywhere
            self.all = all
        }

        func place(of index: Int) -> Place? {
            places[index]
        }

        /// Pre-order indexes of the nodes that may cover `point`, in tree order.
        func near(_ point: UIPoint) -> [Int] {
            guard point.y >= viewport.y, point.y < viewport.y + viewport.height, let row = Self.row(of: point.y, in: viewport) else { return all }
            guard !anywhere.isEmpty else { return rows[row] }
            return Array(Set(rows[row]).union(anywhere)).sorted()
        }

        /// The row of the viewport holding `y`, clamped to the rows; nil for a size or place that is not finite.
        private static func row(of y: Double, in viewport: UIFrame) -> Int? {
            let height = viewport.height / Double(rowCount)
            let row = ((y - viewport.y) / height).rounded(.down)
            guard height > 0, row.isFinite else { return nil }
            return Int(min(max(row, 0), Double(rowCount - 1)))
        }

        /// A simulator lists an app's windows as children of it that fill the screen.
        static func isWindow(_ node: UINode, of parent: UINode, viewport: UIFrame) -> Bool {
            parent.role == .application && node.frame.map { isBackdrop($0, in: viewport) } == true
        }
    }

    /// The roots a cover check judges: on Android the keyboard's window bounds decide, and its root view spans the screen, so it leaves the judging.
    static func coverRoots(_ roots: [UINode], android: Bool) -> [UINode] {
        android ? roots.filter { $0.role != .keyboard } : roots
    }

    /// The keyboard over the tap point, from the tree already read; on Android its window's bounds decide, as its root view spans the screen.
    static func keyboardCover(_ resolution: TapResolution, in tree: UITree) -> UINode? {
        keyboardCover(resolution, in: tree, index: TreeIndex(roots: tree.roots), touchAreas: keyboardTouchAreas(in: tree))
    }

    /// `keyboardCover(_:in:)` with the tree's index and the keyboard's touch areas already read.
    static func keyboardCover(_ resolution: TapResolution, in tree: UITree, index: TreeIndex, touchAreas: [UIFrame]?) -> UINode? {
        let roots = tree.roots
        let targets = [resolution.target, resolution.matched].compactMap { $0 }
        guard !targets.isEmpty, !targets.contains(where: index.isUnderKeyboard) else {
            return nil
        }
        let keyboardCandidates = resolution.coverCandidates.filter(index.isUnderKeyboard)
        if isHiddenByKeyboard(resolution, in: index) {
            return keyboardCandidates.last ?? roots.first { $0.role == .keyboard }
        }
        if let touchAreas {
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

    /// The helper lists an Android app node the keyboard and the bars beside it wholly cover, marked not visible, so a tap on it lands on one of them.
    static func isHiddenByKeyboard(_ resolution: TapResolution, in tree: TreeIndex) -> Bool {
        guard let target = resolution.target, target.androidVisibleToUser == false, tree.roots.contains(where: { $0.role == .keyboard }) else {
            return false
        }
        return tree.indexes(of: target).contains { index in
            let root = tree.roots[tree.root(of: index)]
            return root.role == .application && root.androidVisibleToUser != false
        }
    }

    /// Where Android's input method windows take touches: their bounds around the keyboard's own nodes; nil on iOS and when no window bounds were read.
    static func keyboardTouchAreas(in tree: UITree) -> [UIFrame]? {
        guard tree.platform == .android, let windows = tree.windows else { return nil }
        let areas = windows.filter { $0.kind == "inputMethod" }.compactMap(\.bounds).filter { $0.width > 0 && $0.height > 0 }
        guard !areas.isEmpty else { return nil }
        guard let viewport = UITree.viewport(in: tree.roots) else { return areas }
        // With no keys listed, a window that spans the screen says nothing about where the keys are.
        guard let keys = keyArea(in: tree.roots, viewport: viewport) else { return areas.filter { !isBackdrop($0, in: viewport) } }
        return areas.compactMap { $0.intersection(keys) }
    }

    /// The box around a keyboard's nodes smaller than a backdrop, since a floating keyboard's window and root view span the screen around its strip of keys.
    private static func keyArea(in roots: [UINode], viewport: UIFrame) -> UIFrame? {
        UIFrame.union(of: roots.filter { $0.role == .keyboard }.flatMap { $0.flattened() }.compactMap(\.frame)
            .filter { $0.width > 0 && $0.height > 0 && !isBackdrop($0, in: viewport) })
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

    /// Anything in a keyboard, else what `CoverJudge` takes for a plausible occluder; a labelled group can be a banner on Android.
    private static func isPlausibleOccluder(_ node: UINode, underKeyboard: Bool) -> Bool {
        underKeyboard || CoverJudge.isPlausibleOccluder(node)
    }

    /// The control a touch on `target` reaches when it says it is disabled: the target itself when it is a control, else the nearest control around it; nil when that control is enabled, does not say, or there is none.
    static func disabledControl(reachedBy target: UINode, in roots: [UINode]) -> UINode? {
        let control = target.isActionable ? target : ancestors(of: target, in: roots).last(where: \.isActionable)
        return control?.enabled == false ? control : nil
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
        if case .labelContains = query {
            return elements.filter(query.matches)
        }
        let value = query.rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        var matches = elements.filter { query.field(of: $0) == value }
        if case .id = query, matches.isEmpty, !value.isEmpty {
            // Native Android ids are `package:id/name`; `--id name` finds them when nothing matches exactly.
            matches = elements.filter { $0.normalizedID?.hasSuffix(":id/" + value) == true }
        }
        return matches
    }

    /// Explains a miss: what the `--label` or `--value` refinement or `--element-type` left out, else the closest values of the field.
    private static func notFoundError(
        roots: [UINode],
        query: AccessibilityQuery,
        elementType: String?,
        viewport: UIFrame?
    ) -> ElementResolutionError {
        if case .all(let primary, _) = query {
            let unrefined = candidates(roots: roots, query: primary, elementType: elementType).matches
            guard !unrefined.isEmpty else {
                return notFoundError(roots: roots, query: primary, elementType: elementType, viewport: viewport)
            }
            return .refinedOut(
                selector: query.selectorDescription,
                candidates: unrefined.prefix(ElementResolutionError.maxListed).map { MatchSummary($0, viewport: viewport) }
            )
        }
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

        if query.kind != "--id", let toast = KnownOverlays.logBoxToast(containing: query.rawValue, in: roots, viewport: viewport) {
            return .inLogBoxToast(kind: query.kind, value: query.rawValue, toast: toast.index)
        }
        let near = nearMatches(roots: roots, query: query, viewport: viewport)
        return .notFound(kind: query.kind, value: query.rawValue, suggestions: near.map(\.match), candidates: near.compactMap(\.summary))
    }

    /// The field a near miss may name: a label as tree output shows it, and no value of an element a mask hides.
    private static func shownField(of node: UINode, query: AccessibilityQuery) -> String? {
        guard let field = query.field(of: node) else { return nil }
        let mask = OutputMasks.current.mask
        switch query.kind {
        case "--id": return field
        case "--value": return mask.hides(id: node.normalizedID, label: node.normalizedLabel) ? nil : LogRedactor.redactValue(field).text
        default: return mask.shownLabel(field, id: node.normalizedID)
        }
    }

    /// The fields closest to the query's text, on-screen elements first, each with the first element showing it.
    private static func nearMatches(roots: [UINode], query: AccessibilityQuery, viewport: UIFrame?) -> [(match: SelectorText.NearMatch, summary: MatchSummary?)] {
        let elements = roots.flatMap { $0.flattened() }
        let onScreen = elements.filter { node in viewport.map { node.frame?.isVisible(in: $0) == true } ?? true }
        let offScreen = elements.filter { node in viewport.map { node.frame?.isVisible(in: $0) != true } ?? false }
        let ordered = onScreen + offScreen
        let fields = ordered.map { Self.shownField(of: $0, query: query) }
        return SelectorText.nearMatches(for: query.rawValue, among: fields.compactMap { $0 }).map { near in
            let summary = fields.firstIndex(of: near.text).map { index in
                var summary = MatchSummary(ordered[index], viewport: viewport)
                summary.closeness = near.closeness
                return summary
            }
            return (near, summary)
        }
    }

    /// What a selector that matched nothing came closest to, for a wait or assert that ends not found; nil when it matched something.
    static func nearMiss(roots: [UINode], query: AccessibilityQuery) -> WaitNearMiss? {
        if case .all(let primary, _) = query {
            return candidates(roots: roots, query: primary, elementType: nil).matches.isEmpty ? nearMiss(roots: roots, query: primary) : nil
        }
        guard candidates(roots: roots, query: query, elementType: nil).matches.isEmpty else { return nil }
        let near = nearMatches(roots: roots, query: query, viewport: UITree.viewport(in: roots))
        guard let first = near.first, let summary = first.summary else { return nil }
        let shown = query.kind == "--id"
            ? summary.id.map { "id=\(TerminalText.field($0))" }
            : summary.label.map { TerminalText.quoted(SelectorText.truncated($0, limit: 44)) }
        let subject = ([summary.role.rawValue] + [shown].compactMap { $0 }).joined(separator: " ")
        return WaitNearMiss(
            summary: "\(subject) \(NearMissPhrase.relation(first.match, kind: query.kind, query: query.rawValue))",
            candidates: near.compactMap { $0.summary?.failureCandidate }
        )
    }

    private static func activationPoint(
        for element: UINode,
        frame: UIFrame
    ) -> (x: Double, y: Double) {
        let centerY = frame.y + (frame.height / 2.0)

        if isWideSwitch(element, frame: frame) {
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
        /// The shared on-screen judgement of the matches, when it was read.
        var front: FrontReading?

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
            if let chosen = stackedPick(matches, roots: ambiguity.roots, stack: stack, viewport: ambiguity.viewport, front: ambiguity.front) {
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

    /// Among several matches, the only one not beneath a page; else the only one a touch at its point reaches, by the shared on-screen judgement (`front`, read on a simulator) or on Android its drawing order;
    /// else, when they all share one activation point, the one a touch there reaches.
    static func stackedPick(_ matches: [UINode], roots: [UINode], stack: ScreenStack, viewport: UIFrame?, front: FrontReading? = nil) -> UINode? {
        let uncovered = matches.filter { !stack.isBeneath($0, in: roots) }
        if uncovered.count == 1 {
            return uncovered[0]
        }
        var pool = uncovered.isEmpty ? matches : uncovered
        if let front, !front.isEmpty {
            let reached = pool.filter { front.reason(for: $0, in: roots) == nil }
            if reached.count == 1 {
                return reached[0]
            }
            pool = reached.isEmpty ? pool : reached
        }
        if let viewport, pool.contains(where: \.isAndroid) {
            let judged = coverRoots(roots, android: true)
            let judgedStack = judged.count == roots.count ? stack : ScreenStack.build(roots: judged, viewport: viewport)
            let reached = pool.filter { match in
                guard let frame = match.frame else { return true }
                let point = activationPoint(for: match, frame: frame)
                return CoverJudge.drawnCover(of: match, at: UIPoint(x: point.x, y: point.y), roots: judged, viewport: viewport, stack: judgedStack) == nil
            }
            if reached.count == 1 {
                return reached[0]
            }
        }
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

/// A selector that matched nothing on a read cut short, so the element may lie past where the read stopped.
struct CutTreeMiss: LocalizedError, UserFacingError, OffsiderFailure {
    let miss: ElementResolutionError
    /// `at 64 levels`, or how the source stopped.
    let cut: String

    /// `miss` with the line, when `tree` was cut; else `miss` as it was.
    static func wrapping(_ miss: ElementResolutionError, tree: UITree) -> any Error {
        guard case .notFound = miss else { return miss }
        if let truncation = tree.truncated {
            let limits = [truncation.depth ? "\(UITreeLimits.maxDepth) levels" : nil, truncation.nodes ? "\(UITreeLimits.maxNodes.formatted()) elements" : nil]
            return CutTreeMiss(miss: miss, cut: "The tree was cut at \(limits.compactMap { $0 }.joined(separator: " and ")), so it may be further down.")
        }
        guard tree.sourceTruncated else { return miss }
        return CutTreeMiss(miss: miss, cut: "The tree was cut where the read stopped, so it may be further down.")
    }

    var userFacingDescription: String { miss.userFacingDescription + " " + cut }
    var errorDescription: String? { userFacingDescription }
    var reason: FailureReason { miss.reason }
    var failureMessage: String { userFacingDescription }
    var hint: String? { miss.hint }
    var candidates: [FailureCandidate] { miss.candidates }
}
