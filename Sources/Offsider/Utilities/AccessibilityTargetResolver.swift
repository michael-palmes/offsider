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
        case .value: return node.normalizedValue
        }
    }
}

/// One ambiguous match, as an error lists it.
struct MatchSummary: Equatable {
    let role: UIRole
    let id: String?
    let frame: UIFrame?
    /// Nil when the tree has no screen to compare with.
    let isOnScreen: Bool?

    var text: String {
        var parts = [role.rawValue]
        if let id { parts.append("id=\(id)") }
        parts.append(frame?.summary ?? "with no frame")
        if isOnScreen == false { parts.append("off screen") }
        return parts.joined(separator: " ")
    }
}

enum ElementResolutionError: LocalizedError, UserFacingError {
    case notFound(kind: String, value: String, suggestions: [String] = [])
    case filteredByElementType(kind: String, value: String, elementType: String, roles: [UIRole])
    case offScreen(selector: String, frames: [UIFrame], viewport: UIFrame)
    case multipleMatches(count: Int, kind: String, value: String, hasUniqueIDs: Bool, candidates: [MatchSummary] = [], onScreenOnly: Bool = false, offScreenIgnored: Int = 0)
    case invalidFrame(reason: String)
    case multipleSwitchDescendants(count: Int, selectorDescription: String)

    static let maxListed = 5

    var errorDescription: String? {
        let tip = AccessibilityTargetResolver.describeUITip
        switch self {
        case .notFound(let kind, let value, let suggestions):
            guard !suggestions.isEmpty else {
                return "No accessibility element matched \(kind) '\(value)'. \(tip)"
            }
            let quoted = suggestions.map { "'\(SelectorText.truncated($0))'" }
            return "No accessibility element matched \(kind) '\(value)'. Did you mean \(Self.alternatives(quoted))? \(tip)"
        case .filteredByElementType(let kind, let value, let elementType, let roles):
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
        case .multipleSwitchDescendants(let count, let selectorDescription):
            return "Matched element for \(selectorDescription) contains multiple (\(count)) switch/toggle controls. Target the switch more specifically with --id when available, or use coordinates. Use --element-type only when describe-ui reports a specific role or type, such as switch or Toggle. \(tip)"
        }
    }

    /// Missing, filtered out or off screen: a later tree may show the element, so `--wait-timeout` polls again.
    var isRetryable: Bool {
        switch self {
        case .notFound, .filteredByElementType, .offScreen:
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
        logger: OffsiderLogger? = nil
    ) throws -> AccessibilityMatch {
        let found = candidates(roots: roots, query: query, elementType: elementType)
        guard !found.matches.isEmpty else {
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
            offScreenIgnored: found.matches.count - pool.count
        )
        let element: UINode
        switch query {
        case .id:
            element = try selectUniqueMatch(pool, ambiguity)
        case .label, .value:
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
        logger: OffsiderLogger? = nil
    ) throws -> TapResolution {
        let match = try resolveElement(roots: roots, query: query, elementType: elementType, allowOffscreen: allowOffscreen, logger: logger)

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

        let candidates = allowOffscreen ? [] : UITree.viewport(in: roots).map { viewport in
            coverCandidates(of: activationElement, matched: match.element, at: UIPoint(x: point.x, y: point.y), viewport: viewport, roots: roots)
        } ?? []
        return TapResolution(
            point: point,
            isSwitchLikeControl: activationElement.isSwitch,
            target: activationElement,
            matched: match.element,
            coverCandidates: candidates
        )
    }

    /// Plausible occluders whose frame holds `point`; tree order is not z-order on iOS, so a real hit-test must confirm one.
    static func coverCandidates(of target: UINode, matched: UINode, at point: UIPoint, viewport: UIFrame, roots: [UINode]) -> [UINode] {
        let related = family(of: target, in: roots) + family(of: matched, in: roots)
        var found: [UINode] = []
        func visit(_ node: UINode, underKeyboard: Bool) {
            let underKeyboard = underKeyboard || node.role == .keyboard
            if let frame = coverArea(of: node, in: viewport), frame.contains(point), frame.isVisible(in: viewport),
               isPlausibleOccluder(node, underKeyboard: underKeyboard),
               !related.contains(where: { $0.isSameElement(as: node) }) {
                found.append(node)
            }
            for child in node.children {
                visit(child, underKeyboard: underKeyboard)
            }
        }
        for root in roots {
            visit(root, underKeyboard: false)
        }
        return found
    }

    /// The node's frame, or for a LogBox banner the strip beneath it that its unlisted touch container swallows.
    private static func coverArea(of node: UINode, in viewport: UIFrame) -> UIFrame? {
        guard let frame = node.frame else { return nil }
        return KnownOverlays.isLogBoxBanner(node.label) ? KnownOverlays.logBoxTouchArea(of: frame, in: viewport) : frame
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

    /// Covers at least 80 percent of the viewport, as a modal backdrop or scrim does; a banner covers far less.
    static func isBackdrop(_ frame: UIFrame, in viewport: UIFrame) -> Bool {
        guard let visible = frame.intersection(viewport), viewport.width > 0, viewport.height > 0 else { return false }
        return visible.width * visible.height >= 0.8 * viewport.width * viewport.height
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
                    roles: untyped.matches.map(\.role)
                )
            }
        }

        let elements = roots.flatMap { $0.flattened() }
        let onScreen = elements.filter { node in viewport.map { node.frame?.isVisible(in: $0) == true } ?? true }
        let offScreen = elements.filter { node in viewport.map { node.frame?.isVisible(in: $0) != true } ?? false }
        let values = (onScreen + offScreen).compactMap { query.field(of: $0) }
        return .notFound(
            kind: query.kind,
            value: query.rawValue,
            suggestions: SelectorText.suggestions(for: query.rawValue, among: values)
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
    }

    private static func selectUniqueMatch(
        _ matches: [UINode],
        _ ambiguity: Ambiguity
    ) throws -> UINode {
        guard !matches.isEmpty else {
            throw ElementResolutionError.notFound(kind: ambiguity.query.kind, value: ambiguity.query.rawValue)
        }
        guard matches.count == 1 else {
            let hasUniqueIDs = matches.contains {
                $0.normalizedID != nil
            }
            let summaries = matches.prefix(ElementResolutionError.maxListed).map { node in
                MatchSummary(
                    role: node.role,
                    id: node.normalizedID,
                    frame: node.frame,
                    isOnScreen: ambiguity.viewport.map { node.frame?.isVisible(in: $0) == true }
                )
            }
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
