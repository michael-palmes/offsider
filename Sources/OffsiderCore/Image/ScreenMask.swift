import Foundation

/// What a screenshot mask was asked to cover, in the order `maskedBy` lists them.
public enum MaskKind: String, CaseIterable, Sendable {
    case secure
    case id
    case label
    case text
    case emails
    case region
}

/// Patterns for personal data, shared by screenshot masks and log redaction.
public enum PersonalData {
    /// An email address between word boundaries: a local part, `@`, and a domain ending in a dot and at least two letters,
    /// whose first label is not all digits, so `expo-dev-client@6.0.0-canary.rc` reads as a version.
    public static let emailPattern = #"\b[A-Za-z0-9._%+-]+@(?![0-9]+[.-])[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}\b"#
}

/// The masks one screenshot asked for.
public struct MaskPlan: Equatable, Sendable {
    public var secure: Bool
    public var ids: [String]
    public var labels: [String]
    /// Case-insensitive ICU regular expressions.
    public var texts: [String]
    public var emails: Bool
    /// Points, painted before any `--region` crop.
    public var regions: [PointRegion]

    public init(secure: Bool = false, ids: [String] = [], labels: [String] = [], texts: [String] = [], emails: Bool = false, regions: [PointRegion] = []) {
        self.secure = secure
        self.ids = ids
        self.labels = labels
        self.texts = texts
        self.emails = emails
        self.regions = regions
    }

    public static let none = MaskPlan()

    public var isEmpty: Bool { kinds.isEmpty }

    /// Only regions can be painted without reading the accessibility tree.
    public var needsTree: Bool {
        secure || !ids.isEmpty || !labels.isEmpty || !texts.isEmpty || emails
    }

    /// The kinds asked for, in `MaskKind` order.
    public var kinds: [MaskKind] {
        MaskKind.allCases.filter { kind in
            switch kind {
            case .secure: secure
            case .id: !ids.isEmpty
            case .label: !labels.isEmpty
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
            let frames = Self.leafMostMatches(in: tree.roots, regex: try Self.compile(pattern)).map(\.frame)
            targets.frames[.text, default: []] += frames
            if frames.isEmpty {
                targets.unmatched.append("--mask-text \(pattern)")
            }
        }
        if emails {
            targets.frames[.emails] = Self.leafMostMatches(in: tree.roots, regex: try Self.compile(PersonalData.emailPattern)).map(\.frame)
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

    public init(frames: [MaskKind: [UIFrame?]] = [:], unmatched: [String] = []) {
        self.frames = frames
        self.unmatched = unmatched
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
