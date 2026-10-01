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
}

enum ElementResolutionError: LocalizedError, UserFacingError {
    case notFound(kind: String, value: String)
    case multipleMatches(count: Int, kind: String, value: String, hasUniqueIDs: Bool)
    case invalidFrame(reason: String)
    case multipleSwitchDescendants(count: Int, selectorDescription: String)

    var errorDescription: String? {
        let tip = AccessibilityTargetResolver.describeUITip
        switch self {
        case .notFound(let kind, let value):
            return "No accessibility element matched \(kind) '\(value)'. \(tip)"
        case .multipleMatches(let count, let kind, let value, let hasUniqueIDs):
            if hasUniqueIDs {
                return "Multiple (\(count)) accessibility elements matched \(kind) '\(value)'. Use --id when labels are not unique. \(tip)"
            }
            return "Multiple (\(count)) accessibility elements matched \(kind) '\(value)', and none of the matches expose an id on this screen. Use coordinates for this step (tap -x/-y) or target a more specific screen/state. \(tip)"
        case .invalidFrame(let reason):
            return "\(reason) \(tip)"
        case .multipleSwitchDescendants(let count, let selectorDescription):
            return "Matched element for \(selectorDescription) contains multiple (\(count)) switch/toggle controls. Target the switch more specifically with --id when available, or use coordinates. Use --element-type only when describe-ui reports a specific role or type, such as switch or Toggle. \(tip)"
        }
    }

    var isNotFound: Bool {
        if case .notFound = self { return true }
        return false
    }

    var userFacingDescription: String {
        errorDescription ?? "Offsider could not resolve the requested accessibility element."
    }
}

struct AccessibilityMatch {
    let element: UINode
    let selectorDescription: String
    let applicationFrame: UIFrame?
}

struct AccessibilityTargetResolver {
    static let describeUITip = "Make sure the app is on the expected screen, then run `offsider describe-ui --device <DEVICE_ID>` and prefer --id when available."

    private static let wideSwitchActivationWidthThreshold = 100.0
    private static let switchTrailingActivationInset = 31.0

    static func resolveTapPoint(
        roots: [UINode],
        query: AccessibilityQuery,
        elementType: String? = nil
    ) throws -> (x: Double, y: Double) {
        try resolveTap(roots: roots, query: query, elementType: elementType).point
    }

    static func resolveElement(
        roots: [UINode],
        query: AccessibilityQuery,
        elementType: String? = nil
    ) throws -> AccessibilityMatch {
        var allElements = roots.flatMap { $0.flattened() }

        if let elementType {
            allElements = allElements.filter { $0.matches(elementType: elementType) }
        }

        let matchedElement: UINode
        let selectorDescription: String

        switch query {
        case .id(let rawValue):
            let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            var matches = allElements.filter { $0.normalizedID == value }
            if matches.isEmpty, !value.isEmpty {
                // Native Android ids are `package:id/name`; `--id name` finds them when nothing matches exactly.
                matches = allElements.filter { $0.normalizedID?.hasSuffix(":id/" + value) == true }
            }
            matchedElement = try selectUniqueMatch(matches, kind: "--id", value: rawValue)
            selectorDescription = "--id '\(rawValue)'"
        case .label(let rawValue):
            let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let matches = allElements.filter { $0.normalizedLabel == value }
            matchedElement = try selectBestLabelMatch(matches, value: rawValue)
            selectorDescription = "--label '\(rawValue)'"
        case .value(let rawValue):
            let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let matches = allElements.filter { $0.normalizedValue == value }
            matchedElement = try selectBestLabelMatch(matches, kind: "--value", value: rawValue)
            selectorDescription = "--value '\(rawValue)'"
        }

        return AccessibilityMatch(
            element: matchedElement,
            selectorDescription: selectorDescription,
            applicationFrame: UITree.applicationFrame(in: roots)
        )
    }

    static func resolveTap(
        roots: [UINode],
        query: AccessibilityQuery,
        elementType: String? = nil
    ) throws -> TapResolution {
        let match = try resolveElement(roots: roots, query: query, elementType: elementType)

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

        return TapResolution(
            point: activationPoint(for: activationElement, frame: frame),
            isSwitchLikeControl: activationElement.isSwitch
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

    private static func selectUniqueMatch(
        _ matches: [UINode],
        kind: String,
        value: String
    ) throws -> UINode {
        guard !matches.isEmpty else {
            throw ElementResolutionError.notFound(kind: kind, value: value)
        }
        guard matches.count == 1 else {
            let hasUniqueIDs = matches.contains {
                $0.normalizedID != nil
            }
            throw ElementResolutionError.multipleMatches(count: matches.count, kind: kind, value: value, hasUniqueIDs: hasUniqueIDs)
        }
        return matches[0]
    }

    private static func selectBestLabelMatch(
        _ matches: [UINode],
        kind: String = "--label",
        value: String
    ) throws -> UINode {
        let switchLikeMatches = matches.filter(\.isSwitch)
        if switchLikeMatches.count == 1 {
            return switchLikeMatches[0]
        }
        if switchLikeMatches.count > 1 {
            return try selectUniqueMatch(switchLikeMatches, kind: kind, value: value)
        }

        let actionableMatches = matches.filter(\.role.isActionable)
        if actionableMatches.count == 1 {
            return actionableMatches[0]
        }

        if actionableMatches.count > 1 {
            return try selectUniqueMatch(actionableMatches, kind: kind, value: value)
        }

        return try selectUniqueMatch(matches, kind: kind, value: value)
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
        if sameElement(currentElement, matchedElement) {
            return parent
        }

        for child in currentElement.children {
            if let ancestor = nearestAncestor(of: matchedElement, in: child, parent: currentElement) {
                return ancestor
            }
        }
        return nil
    }

    /// The matched node is a copy from this tree, so every field but the children identifies it.
    private static func sameElement(_ lhs: UINode, _ rhs: UINode) -> Bool {
        lhs.role == rhs.role
            && lhs.id == rhs.id
            && lhs.label == rhs.label
            && lhs.value == rhs.value
            && lhs.frame == rhs.frame
            && lhs.enabled == rhs.enabled
            && lhs.state == rhs.state
            && lhs.native == rhs.native
    }
}

extension UINode {
    var normalizedID: String? { Self.trimmed(id) }
    var normalizedLabel: String? { Self.trimmed(label) }
    var normalizedValue: String? { Self.trimmed(value) }
    var isSwitch: Bool { role == .switch }
    var isSlider: Bool { role == .slider }

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
