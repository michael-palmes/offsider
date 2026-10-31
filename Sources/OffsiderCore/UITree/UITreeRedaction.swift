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
    /// What the device's reads showed that only their nesting hides, for messages that name one element.
    public var nested = NestedMasks()

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

    public func hidesValue(of node: UINode) -> Bool {
        hides(id: node.normalizedID, label: node.normalizedLabel)
    }

    /// Whether a masked id or label names the element with this trimmed `id` and `label`, so output hides its text.
    public func hides(id: String?, label: String?) -> Bool {
        guard hidesElements else { return false }
        if let id, ids.contains(id) || nested.ids.contains(id) { return true }
        guard let label else { return false }
        if labels.contains(label) || nested.labels.contains(label) { return true }
        guard !foldedLabels.isEmpty || !labelContains.isEmpty else { return false }
        let folded = Self.folded(label)
        return foldedLabels.contains(folded) || labelContains.contains { folded.contains($0) }
    }

    /// An exact `labels` match whole, else only the text `labelContains` names with the rest `[redacted]`, else `[redacted]`.
    public func maskedLabel(_ label: String) -> String {
        let folded = Self.folded(label)
        guard !folded.isEmpty else { return label }
        if labels.contains(label.trimmingCharacters(in: .whitespacesAndNewlines)) || foldedLabels.contains(folded) { return label }
        let named = labelContains.compactMap { folded.range(of: $0) }.sorted { $0.lowerBound < $1.lowerBound }
        guard !named.isEmpty else { return LogRedactor.marker }
        var shown = ""
        var cursor = folded.startIndex
        for range in named where range.upperBound > cursor {
            let start = max(cursor, range.lowerBound)
            shown += Self.gap(folded[cursor..<start]) + folded[start..<range.upperBound]
            cursor = range.upperBound
        }
        return shown + Self.gap(folded[cursor...])
    }

    /// Hidden text between named parts: the marker, with a space kept on either side so the words around it stay apart.
    private static func gap(_ text: Substring) -> String {
        guard text.contains(where: { !$0.isWhitespace }) else { return String(text) }
        return (text.first?.isWhitespace == true ? " " : "") + LogRedactor.marker + (text.last?.isWhitespace == true ? " " : "")
    }

    /// A label of the element with `id` as tree output shows it: masked when a mask names the element, else with secrets redacted.
    public func shownLabel(_ label: String, id: String?) -> String {
        if let masked = masked(label, id: id) { return masked }
        if let rewritten = rewritten(label) { return rewritten }
        return redactedText(label)
    }

    /// A page or window name, which keeps `LogRedactor`'s email, key-value and JWT passes and adds the mask's patterns.
    public func contextLabel(_ label: String, id: String?) -> String {
        if let masked = masked(label, id: id) { return masked }
        if let rewritten = rewritten(label) { return rewritten }
        var count = 0
        return maskText(LogRedactor.redact(label).text, count: &count)
    }

    /// `text` with secrets and the mask's patterns replaced, for a message that holds screen text but names no element.
    public func redactedText(_ text: String) -> String {
        var count = 0
        return UITree.redactText(text, mask: self, count: &count)
    }

    private func rewritten(_ label: String) -> String? {
        guard !nested.rewrites.isEmpty, let trimmed = Self.trimmed(label) else { return nil }
        return nested.rewrites[trimmed]
    }

    /// `label` as `maskedLabel` shows it when a mask names the element with `id`, else nil.
    public func masked(_ label: String, id: String?) -> String? {
        hides(id: Self.trimmed(id), label: Self.trimmed(label)) ? maskedLabel(label) : nil
    }

    /// `node`'s label as tree output shows it.
    public func shownLabel(of node: UINode) -> String? {
        node.label.map { shownLabel($0, id: node.normalizedID) }
    }

    private static func trimmed(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
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

/// Elements a read showed that no mask names alone: those under a masked element, and labels that copy a masked element's text.
public struct NestedMasks: Equatable, Sendable {
    public var ids: Set<String> = []
    public var labels: Set<String> = []
    /// A label as read, trimmed, and as output shows it.
    public var rewrites: [String: String] = [:]

    public init() {}

    var count: Int { ids.count + labels.count + rewrites.count }
}

/// The masks the elements a command's messages name honour, read the first time one is named.
public final class OutputMasks: @unchecked Sendable {
    /// None unless the command binds its own; a test binds its own too.
    @TaskLocal public static var current = OutputMasks { .none }

    /// Past this many remembered elements, a long wait over rotating text starts again from its latest read.
    static let maximumNested = 4096

    private let read: @Sendable () -> TreeValueMask
    private let lock = NSLock()
    private var cached: TreeValueMask?
    private var nested = NestedMasks()

    public init(_ read: @escaping @Sendable () -> TreeValueMask) {
        self.read = read
    }

    /// The masks with what this command's reads have shown, for naming one element.
    public var mask: TreeValueMask {
        var mask = base
        lock.lock()
        mask.nested = nested
        lock.unlock()
        return mask
    }

    /// The masks alone, for redacting a whole tree, whose nesting then speaks for itself.
    public var base: TreeValueMask {
        lock.lock()
        defer { lock.unlock() }
        if let cached { return cached }
        let mask = read()
        cached = mask
        return mask
    }

    /// Remembers what `tree`'s nesting hides, so a later message about one of its elements hides it too.
    public func note(_ tree: UITree) {
        let base = base
        guard base.hidesElements else { return }
        var seen = NestedMasks()
        let shown = tree.redacted(base)
        for (raw, shown) in zip(tree.roots, shown.roots) {
            Self.collect(raw, shown: shown, inherited: false, mask: base, into: &seen)
        }
        lock.lock()
        defer { lock.unlock() }
        if nested.count + seen.count > Self.maximumNested { nested = NestedMasks() }
        nested.ids.formUnion(seen.ids)
        nested.labels.formUnion(seen.labels)
        nested.rewrites.merge(seen.rewrites) { _, new in new }
    }

    private static func collect(_ raw: UINode, shown: UINode, inherited: Bool, mask: TreeValueMask, into seen: inout NestedMasks) {
        let own = mask.hidesValue(of: raw)
        if inherited, !own {
            if let id = raw.normalizedID { seen.ids.insert(id) }
            if let label = raw.normalizedLabel { seen.labels.insert(label) }
        } else if !own, let label = raw.normalizedLabel, let text = shown.label, text != raw.label {
            seen.rewrites[label] = text
        }
        let passes = (inherited || own) && raw.passesMaskDown
        for (child, shownChild) in zip(raw.children, shown.children) {
            collect(child, shown: shownChild, inherited: passes, mask: mask, into: &seen)
        }
    }
}

/// Where a tree is going: shown to the reader (every value pattern too), or into the tree cache (values and masked labels only).
public enum TreeRedactionScope: Sendable {
    case output
    case cache
}

extension UITree {
    /// A copy with masked elements' text and revealed values hidden and, for output, secrets in labels and values redacted; ids are never touched.
    /// Output trees carry the counts, which the renderer prints.
    public func redacted(_ mask: TreeValueMask = .none, scope: TreeRedactionScope = .output) -> UITree {
        var counts = UITreeRedactionCounts()
        var copy = self
        var hiddenBelow: [(text: String, shown: String)] = []
        for index in copy.roots.indices {
            hiddenBelow.removeAll(keepingCapacity: true)
            Self.redact(&copy.roots[index], mask: mask, scope: scope, inherited: false, hiddenBelow: &hiddenBelow, counts: &counts)
        }
        if scope == .output {
            copy.redaction = counts
        }
        return copy
    }

    /// Children first, so `hiddenBelow` holds each hidden descendant's text and how it reads for this node's label, which may copy it.
    private static func redact(
        _ node: inout UINode, mask: TreeValueMask, scope: TreeRedactionScope, inherited: Bool, hiddenBelow: inout [(text: String, shown: String)],
        counts: inout UITreeRedactionCounts
    ) {
        let isMasked = inherited || mask.hidesValue(of: node)
        let revealed = mask.revealed?.matches(node) == true
        let below = hiddenBelow.count
        let passes = isMasked && node.passesMaskDown
        for index in node.children.indices {
            redact(&node.children[index], mask: mask, scope: scope, inherited: passes, hiddenBelow: &hiddenBelow, counts: &counts)
        }
        if !isMasked, hiddenBelow.count > below {
            rewrite(&node, hiding: hiddenBelow[below...], counts: &counts)
        }
        let original = (label: node.label, value: node.value, text: node.native.text)
        let holdsText = node.value?.isEmpty == false || node.native.text?.isEmpty == false
        if revealed, holdsText { counts.revealed += 1 }
        if isMasked {
            let label = node.label.map(mask.maskedLabel)
            if (holdsText && !revealed) || label != node.label { counts.redacted += 1 }
            node.native.hideText(label: node.label, shown: label)
            node.label = label
            node.value = hidden(node.value)
        } else {
            switch scope {
            case .cache:
                node.value = node.value.map { mask.maskText($0, count: &counts.redacted) }
            case .output:
                node.label = node.label.map { redactText($0, mask: mask, count: &counts.redacted) }
                if !revealed { node.value = node.value.map { redactText($0, mask: mask, count: &counts.redacted) } }
                node.native.redactText { text in
                    revealed && (text == original.value || text == original.text) ? LogRedactor.marker : redactText(text, mask: mask, count: &counts.redacted)
                }
            }
        }
        if revealed {
            node.value = SecureText.masked(original.value)
            node.native.text = SecureText.masked(original.text)
        }
        guard isMasked || revealed else { return }
        if isMasked, let label = original.label, let shown = node.label, label != shown { hiddenBelow.append((label, shown)) }
        for text in [original.value, original.text].compactMap({ $0 }) where text.contains(where: { !$0.isWhitespace }) {
            hiddenBelow.append((text, LogRedactor.marker))
        }
    }

    /// An ancestor's copies of hidden descendants' text, longest first, so a text inside another never splits it.
    private static func rewrite(_ node: inout UINode, hiding hidden: ArraySlice<(text: String, shown: String)>, counts: inout UITreeRedactionCounts) {
        let longestFirst = hidden.sorted { $0.text.count > $1.text.count }
        var changed = false
        let hide = { (text: String) -> String in
            var result = text
            for entry in longestFirst where result.contains(entry.text) {
                result = result.replacingOccurrences(of: entry.text, with: entry.shown)
            }
            if result != text { changed = true }
            return result
        }
        node.label = node.label.map(hide)
        node.value = node.value.map(hide)
        node.native.redactText(hide)
        if changed { counts.redacted += 1 }
    }

    private static func hidden(_ text: String?) -> String? {
        guard let text, !text.isEmpty else { return text }
        return LogRedactor.marker
    }

    /// Strings under six bytes cannot hold a code, address, card or phrase, so they skip the patterns.
    static func redactText(_ text: String, mask: TreeValueMask, count: inout Int) -> String {
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

    /// A masked element's screen text: a copy of its label as `shown`, everything else hidden.
    mutating func hideText(label: String?, shown: String?) {
        let hide = { (text: String) in text == label ? (shown ?? LogRedactor.marker) : (text.isEmpty ? text : LogRedactor.marker) }
        redactText(hide)
    }

    /// Every attribute that carries screen text, transformed in place.
    mutating func redactText(_ transform: (String) -> String) {
        switch self {
        case .ios(var attributes):
            attributes.title = attributes.title.map(transform)
            attributes.help = attributes.help.map(transform)
            attributes.roleDescription = attributes.roleDescription.map(transform)
            attributes.customActions = attributes.customActions.map(transform)
            self = .ios(attributes)
        case .android(var attributes):
            attributes.text = attributes.text.map(transform)
            attributes.contentDescription = attributes.contentDescription.map(transform)
            attributes.hint = attributes.hint.map(transform)
            attributes.stateDescription = attributes.stateDescription.map(transform)
            attributes.roleDescription = attributes.roleDescription.map(transform)
            self = .android(attributes)
        }
    }
}

extension UINode {
    /// A mask on the app or a window names the screen itself, whose name may hold anything, so it stops there.
    var passesMaskDown: Bool { role != .application && role != .window }
}
