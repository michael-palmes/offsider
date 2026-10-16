import Foundation

/// How many values one tree's output hid: text the value patterns or masks replaced, and password fields shown as plain text.
public struct UITreeRedactionCounts: Equatable, Sendable {
    public var redacted: Int
    public var revealed: Int

    public init(redacted: Int = 0, revealed: Int = 0) {
        self.redacted = redacted
        self.revealed = revealed
    }

    public var isEmpty: Bool { redacted == 0 && revealed == 0 }

    /// `# redacted: 2 values, 1 revealed password field`.
    public var footer: String {
        var parts: [String] = []
        if redacted > 0 { parts.append("\(redacted) value\(redacted == 1 ? "" : "s")") }
        if revealed > 0 { parts.append("\(revealed) revealed password field\(revealed == 1 ? "" : "s")") }
        return "# redacted: " + parts.joined(separator: ", ")
    }
}

/// What hides element values: masked ids and labels (from `offsider.mask.json` and the evidence run), value patterns,
/// email addresses and password fields a show-password toggle revealed.
public struct TreeValueMask: @unchecked Sendable {
    public var ids: Set<String>
    public var labels: Set<String>
    public var foldedLabels: Set<String>
    public var labelContains: [String]
    public var patterns: [NSRegularExpression]
    public var emails: Bool
    public var revealed: RevealedSecrets?

    public static let none = TreeValueMask()

    public init(
        ids: [String] = [], labels: [String] = [], labelContains: [String] = [], patterns: [NSRegularExpression] = [], emails: Bool = false,
        revealed: RevealedSecrets? = nil
    ) {
        self.ids = Set(ids)
        let trimmed = labels.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        self.labels = Set(trimmed)
        self.foldedLabels = Set(trimmed.map(SelectorText.folded))
        self.labelContains = labelContains.map(SelectorText.folded).filter { !$0.isEmpty }
        self.patterns = Self.joined(patterns)
        self.emails = emails
        self.revealed = revealed.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// A screenshot plan's id, label, text and email masks; password fields and regions have no value to hide here.
    public init(plan: MaskPlan, revealed: RevealedSecrets? = nil) throws {
        self.init(
            ids: plan.ids, labels: plan.labels, labelContains: plan.labelsContaining, patterns: try plan.texts.map(MaskPlan.compile),
            emails: plan.emails, revealed: revealed
        )
    }

    private static let email = try! NSRegularExpression(pattern: PersonalData.emailPattern)

    /// The patterns as one alternation, so each string is scanned once; kept apart when one refers back to its own groups.
    static func joined(_ patterns: [NSRegularExpression]) -> [NSRegularExpression] {
        guard patterns.count > 1, !patterns.contains(where: { $0.pattern.range(of: #"\\[1-9k]"#, options: .regularExpression) != nil }),
              let joined = try? NSRegularExpression(pattern: patterns.map { "(?:\($0.pattern))" }.joined(separator: "|"), options: [.caseInsensitive]) else {
            return patterns
        }
        return [joined]
    }

    var hidesElements: Bool { !ids.isEmpty || !labels.isEmpty || !labelContains.isEmpty }

    func hidesValue(of node: UINode) -> Bool {
        guard hidesElements else { return false }
        if let id = node.normalizedID, ids.contains(id) { return true }
        guard let label = node.normalizedLabel else { return false }
        if labels.contains(label) { return true }
        guard !foldedLabels.isEmpty || !labelContains.isEmpty else { return false }
        let folded = Self.folded(label)
        return foldedLabels.contains(folded) || labelContains.contains { folded.contains($0) }
    }

    /// `SelectorText.folded`, skipped for plain ASCII with single spaces, which it would leave as it is.
    static func folded(_ text: String) -> String {
        var previousSpace = true
        for byte in text.utf8 {
            let space = byte == 0x20
            guard (0x21...0x7E).contains(byte) || (space && !previousSpace), byte != 0x60 else {
                return SelectorText.folded(text)
            }
            previousSpace = space
        }
        return previousSpace ? SelectorText.folded(text) : text
    }

    /// The text with pattern and email matches replaced, adding each replacement to `count`.
    func maskText(_ text: String, count: inout Int) -> String {
        var result = text
        for pattern in patterns {
            result = Self.replace(pattern, in: result, with: LogRedactor.marker, count: &count)
        }
        if emails, result.contains("@") {
            result = Self.replace(Self.email, in: result, with: LogRedactor.emailMarker, count: &count)
        }
        return result
    }

    private static func replace(_ regex: NSRegularExpression, in text: String, with marker: String, count: inout Int) -> String {
        let range = NSRange(text.startIndex..., in: text)
        let matches = regex.numberOfMatches(in: text, range: range)
        guard matches > 0 else { return text }
        count += matches
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: NSRegularExpression.escapedTemplate(for: marker))
    }
}

/// Where a tree is going: shown to the reader (every value pattern too), or into the tree cache (values only, labels kept as identity).
public enum TreeRedactionScope: Sendable {
    case output
    case cache
}

extension UITree {
    /// A copy with masked and revealed values hidden and, for output, secrets in labels and values redacted; ids are never touched.
    /// Output trees carry the counts, which the renderer prints.
    public func redacted(_ mask: TreeValueMask = .none, scope: TreeRedactionScope = .output) -> UITree {
        var counts = UITreeRedactionCounts()
        var copy = self
        for index in copy.roots.indices {
            Self.redact(&copy.roots[index], mask: mask, scope: scope, counts: &counts)
        }
        if scope == .output {
            copy.redaction = counts
        }
        return copy
    }

    private static func redact(_ node: inout UINode, mask: TreeValueMask, scope: TreeRedactionScope, counts: inout UITreeRedactionCounts) {
        if let revealed = mask.revealed, revealed.matches(node) {
            if node.value?.isEmpty == false || node.native.text?.isEmpty == false { counts.revealed += 1 }
            node.value = SecureText.masked(node.value)
            node.native.text = SecureText.masked(node.native.text)
        } else if mask.hidesValue(of: node) {
            if node.value?.isEmpty == false || node.native.text?.isEmpty == false { counts.redacted += 1 }
            node.value = hidden(node.value)
            node.native.text = hidden(node.native.text)
        } else {
            switch scope {
            case .cache:
                node.value = node.value.map { mask.maskText($0, count: &counts.redacted) }
            case .output:
                node.label = node.label.map { redactText($0, mask: mask, count: &counts.redacted) }
                node.value = node.value.map { redactText($0, mask: mask, count: &counts.redacted) }
                node.native.redactText { redactText($0, mask: mask, count: &counts.redacted) }
            }
        }
        for index in node.children.indices {
            redact(&node.children[index], mask: mask, scope: scope, counts: &counts)
        }
    }

    private static func hidden(_ text: String?) -> String? {
        guard let text, !text.isEmpty else { return text }
        return LogRedactor.marker
    }

    /// Strings under six bytes cannot hold a code, address, card or phrase, so they skip the patterns.
    private static func redactText(_ text: String, mask: TreeValueMask, count: inout Int) -> String {
        var result = text
        if text.utf8.count >= LogRedactor.minimumValueLength {
            let redacted = LogRedactor.redactValue(text)
            count += redacted.count
            result = redacted.text
        }
        return mask.maskText(result, count: &count)
    }
}

extension UINative {
    /// Android's text, which repeats a field's value.
    var text: String? {
        get {
            if case .android(let attributes) = self { return attributes.text }
            return nil
        }
        set {
            if case .android(var attributes) = self {
                attributes.text = newValue
                self = .android(attributes)
            }
        }
    }

    /// Every attribute that carries screen text, transformed in place.
    mutating func redactText(_ transform: (String) -> String) {
        switch self {
        case .ios(var attributes):
            attributes.title = attributes.title.map(transform)
            attributes.help = attributes.help.map(transform)
            self = .ios(attributes)
        case .android(var attributes):
            attributes.text = attributes.text.map(transform)
            attributes.contentDescription = attributes.contentDescription.map(transform)
            attributes.hint = attributes.hint.map(transform)
            attributes.stateDescription = attributes.stateDescription.map(transform)
            self = .android(attributes)
        }
    }
}
