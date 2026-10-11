import Foundation

/// What a screenshot mask was asked to cover, in the order `maskedBy` lists them.
public enum MaskKind: String, CaseIterable, Sendable {
    case secure
    case id
    case label
    case labelContains
    case text
    case emails
    case region
}

/// Patterns for personal data, shared by screenshot masks and log redaction.
public enum PersonalData {
    /// An email address between word boundaries: a local part, `@`, and a domain ending in a dot and at least two letters,
    /// whose first two labels are not both all digits, so `expo-dev-client@6.0.0-canary.rc` reads as a version and `a@163.com` as an address.
    public static let emailPattern = #"\b[A-Za-z0-9._%+-]+@(?![0-9]+\.[0-9]+(?![A-Za-z0-9-]))[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}\b"#
}

/// The masks one screenshot asked for.
public struct MaskPlan: Equatable, Sendable {
    public var secure: Bool
    public var ids: [String]
    public var labels: [String]
    /// Text a label must hold, matched as `--label-contains` matches.
    public var labelsContaining: [String]
    /// Case-insensitive ICU regular expressions.
    public var texts: [String]
    public var emails: Bool
    /// Points, painted before any `--region` crop.
    public var regions: [PointRegion]

    public init(secure: Bool = false, ids: [String] = [], labels: [String] = [], labelsContaining: [String] = [], texts: [String] = [], emails: Bool = false, regions: [PointRegion] = []) {
        self.secure = secure
        self.ids = ids
        self.labels = labels
        self.labelsContaining = labelsContaining
        self.texts = texts
        self.emails = emails
        self.regions = regions
    }

    public static let none = MaskPlan()

    /// Every mask in this plan and in `other`, each selector once.
    public func union(_ other: MaskPlan) -> MaskPlan {
        func merged<T: Equatable>(_ mine: [T], _ theirs: [T]) -> [T] {
            theirs.reduce(into: mine) { result, value in
                if !result.contains(value) { result.append(value) }
            }
        }
        return MaskPlan(
            secure: secure || other.secure,
            ids: merged(ids, other.ids),
            labels: merged(labels, other.labels),
            labelsContaining: merged(labelsContaining, other.labelsContaining),
            texts: merged(texts, other.texts),
            emails: emails || other.emails,
            regions: merged(regions, other.regions)
        )
    }

    public var isEmpty: Bool { kinds.isEmpty }

    /// Only regions can be painted without reading the accessibility tree.
    public var needsTree: Bool {
        secure || !ids.isEmpty || !labels.isEmpty || !labelsContaining.isEmpty || !texts.isEmpty || emails
    }

    /// The kinds asked for, in `MaskKind` order.
    public var kinds: [MaskKind] {
        MaskKind.allCases.filter { kind in
            switch kind {
            case .secure: secure
            case .id: !ids.isEmpty
            case .label: !labels.isEmpty
            case .labelContains: !labelsContaining.isEmpty
            case .text: !texts.isEmpty
            case .emails: emails
            case .region: !regions.isEmpty
            }
        }
    }

    /// Compiles a `--mask-text` pattern case-insensitively, naming it when it is not a valid ICU expression.
    public static func compile(_ pattern: String) throws -> NSRegularExpression {
        do {
            return try NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        } catch {
            throw MaskPatternError(pattern: pattern)
        }
    }

    /// Frames for `--mask-text` and `--mask-emails`: the leaf-most nodes whose readable text matches.
    public func textTargets(in tree: UITree) throws -> MaskTargets {
        var targets = MaskTargets()
        for pattern in texts {
            let nodes = Self.leafMostMatches(in: tree.roots, regex: try Self.compile(pattern))
            targets.add(nodes, as: .text)
            if nodes.isEmpty {
                targets.unmatched.append("--mask-text \(pattern)")
            }
        }
        if emails {
            targets.add(Self.leafMostMatches(in: tree.roots, regex: try Self.compile(PersonalData.emailPattern)), as: .emails)
        }
        return targets
    }

    /// A matching node whose descendant also matches is left to the descendant, so a row is not blacked out for one field.
    static func leafMostMatches(in nodes: [UINode], regex: NSRegularExpression) -> [UINode] {
        nodes.flatMap { node -> [UINode] in
            let below = leafMostMatches(in: node.children, regex: regex)
            if !below.isEmpty { return below }
            return node.searchableText.contains { text in
                regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
            } ? [node] : []
        }
    }
}

/// Frames to paint by kind, and the selectors that matched nothing (`--mask-id profile-email`).
public struct MaskTargets: Equatable, Sendable {
    public var frames: [MaskKind: [UIFrame?]]
    public var unmatched: [String]
    /// The elements behind `frames`, for the kinds read from the tree.
    public var nodes: [MaskKind: [UINode]]

    public init(frames: [MaskKind: [UIFrame?]] = [:], unmatched: [String] = [], nodes: [MaskKind: [UINode]] = [:]) {
        self.frames = frames
        self.unmatched = unmatched
        self.nodes = nodes
    }

    public mutating func add(_ matches: [UINode], as kind: MaskKind) {
        frames[kind, default: []] += matches.map(\.frame)
        nodes[kind, default: []] += matches
    }

    /// The frames of matched elements on a screen beneath a page, by kind; the stack is built only when something matched.
    public func framesBeneathPages(in tree: UITree) -> [MaskKind: [UIFrame?]] {
        guard nodes.values.contains(where: { !$0.isEmpty }) else { return [:] }
        let stack = ScreenStack.build(roots: tree.roots, viewport: tree.viewport)
        guard !stack.beneath.isEmpty else { return [:] }
        let flat = tree.roots.flatMap { $0.flattened() }
        let covered = stack.beneath.flatMap(\.indexes).map { flat[$0] }
        return nodes.mapValues { matches in
            matches.filter { match in covered.contains { $0.isSameElement(as: match) } }.map(\.frame)
        }
    }
}

public struct MaskPatternError: LocalizedError, CustomStringConvertible, Equatable, Sendable {
    public let pattern: String

    public var description: String {
        "Invalid --mask-text pattern: \(pattern). Use an ICU regular expression, and escape characters such as ( [ . * with a backslash to match them literally."
    }

    public var errorDescription: String? { description }
}

extension UINode {
    /// What a person could read: label, value (never a secure one), and the native title, text, content description and hint.
    var searchableText: [String] {
        var texts = [label, isSecure ? nil : value]
        switch native {
        case .ios(let attributes):
            texts.append(attributes.title)
        case .android(let attributes):
            texts += [isSecure ? nil : attributes.text, attributes.contentDescription, attributes.hint]
        }
        return texts.compactMap { $0 }.filter { !$0.isEmpty }
    }
}
