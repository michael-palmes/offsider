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

    /// `--mask-skip-beneath` may leave this kind unpainted beneath a page; password fields and regions are always painted.
    public var skippableBeneath: Bool {
        self != .secure && self != .region
    }
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
    /// Leaves matches of skippable kinds unpainted when their element is on a screen beneath a page.
    public var skipsBeneath: Bool

    public init(
        secure: Bool = false, ids: [String] = [], labels: [String] = [], labelsContaining: [String] = [], texts: [String] = [], emails: Bool = false,
        regions: [PointRegion] = [], skipsBeneath: Bool = false
    ) {
        self.secure = secure
        self.ids = ids
        self.labels = labels
        self.labelsContaining = labelsContaining
        self.texts = texts
        self.emails = emails
        self.regions = regions
        self.skipsBeneath = skipsBeneath
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
            regions: merged(regions, other.regions),
            skipsBeneath: skipsBeneath || other.skipsBeneath
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

/// One matcher's matches from the tree: its kind, and the elements it matched.
public struct MaskGroup: Equatable, Sendable {
    public var kind: MaskKind
    public var nodes: [UINode]

    public init(kind: MaskKind, nodes: [UINode]) {
        self.kind = kind
        self.nodes = nodes
    }
}

/// Frames to paint by kind, and the selectors that matched nothing (`--mask-id profile-email`).
public struct MaskTargets: Equatable, Sendable {
    public var frames: [MaskKind: [UIFrame?]]
    public var unmatched: [String]
    /// The elements behind `frames`, one group per matcher, for the kinds read from the tree.
    public var groups: [MaskGroup]

    public init(frames: [MaskKind: [UIFrame?]] = [:], unmatched: [String] = [], groups: [MaskGroup] = []) {
        self.frames = frames
        self.unmatched = unmatched
        self.groups = groups
    }

    public mutating func add(_ matches: [UINode], as kind: MaskKind) {
        frames[kind, default: []] += matches.map(\.frame)
        groups.append(MaskGroup(kind: kind, nodes: matches))
    }

    /// Places matches by tree position: frames painted beneath a page, and with `skip` the skippable ones left out of `frames`; an unplaceable group is painted whole.
    public mutating func placeBeneath(in tree: UITree, skip: Bool) -> (painted: [MaskKind: [UIFrame?]], skipped: [MaskKind: Int]) {
        guard groups.contains(where: { !$0.nodes.isEmpty }) else { return ([:], [:]) }
        let stack = ScreenStack.build(roots: tree.roots, viewport: tree.viewport)
        guard !stack.beneath.isEmpty else { return ([:], [:]) }
        let flat = tree.roots.flatMap { $0.flattened() }
        var painted: [MaskKind: [UIFrame?]] = [:]
        var skipped: [MaskKind: Int] = [:]
        var placed: [MaskKind: [UIFrame?]] = [:]
        for group in groups {
            // Equal elements match alike, so a group's matches are the elements equal to one of them.
            let positions = flat.indices.filter { index in group.nodes.contains { $0.isSameElement(as: flat[index]) } }
            guard positions.count == group.nodes.count else {
                placed[group.kind, default: []] += group.nodes.map(\.frame)
                continue
            }
            for position in positions {
                let frame = flat[position].frame
                if stack.isBeneath(index: position) {
                    if skip, group.kind.skippableBeneath {
                        skipped[group.kind, default: 0] += 1
                        continue
                    }
                    painted[group.kind, default: []].append(frame)
                }
                placed[group.kind, default: []].append(frame)
            }
        }
        for kind in Set(groups.map(\.kind)) {
            frames[kind] = placed[kind] ?? []
        }
        return (painted, skipped)
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
