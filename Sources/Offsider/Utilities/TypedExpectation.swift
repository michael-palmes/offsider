import Foundation
import OffsiderCore

/// What `type --verify` sent and where, so a verified change can be read back from the field; nothing here is ever printed.
struct TypedExpectation {
    let text: String
    let replacing: Bool
    /// The field as the focus check read it before the text went; nil when it named none.
    let field: UINode?
    /// The `--into-*` selector, which finds the field again on a later read.
    let query: AccessibilityQuery?
    /// A password field: its value never counts.
    let secure: Bool
    let ignoringText: Bool

    /// Whether a read can say anything: never for a password, under `--verify-ignore-text`, for text ending in Return, which may submit the form, or with no field to read.
    var judged: Bool {
        !secure && !InputSecrecy.isSecret && !ignoringText && !text.hasSuffix("\n") && !text.hasSuffix("\r") && (field != nil || query != nil)
    }

    func check(before: UITree?, after: UITree) -> TextCheck {
        guard let now = locate(in: after), !now.isSecure else { return .unknown }
        let was = before.flatMap(locate)?.value ?? field?.value
        guard after.platform == .android else { return TypedText.judge(sent: text, before: was, after: now.value, replacing: replacing) }
        // Android reads an empty field as no value, and a field inside the keyboard holding focus, as Gboard's stylus tutorial's does, took what is missing.
        let check = TypedText.judge(sent: text, before: was, after: now.value ?? "", replacing: replacing)
        return TextFocus.keyboardHoldingFocus(in: after) != nil && Self.lacksText(text, before: was, after: now.value, replacing: replacing) ? .differs : check
    }

    /// Short enough to judge, and not all there: what a keyboard field holding focus took.
    static func lacksText(_ text: String, before: String?, after: String?, replacing: Bool = false) -> Bool {
        guard text.count <= TypedText.longest, (after ?? "").count <= TypedText.longest else { return false }
        return TypedText.judge(sent: text, before: before, after: after ?? "", replacing: replacing) != .match
    }

    /// The field in `tree`: the one `--into-*` matches, else the focused field while it is still the one typed into.
    func locate(in tree: UITree) -> UINode? {
        let nodes = tree.roots.flatMap { $0.flattened() }
        if let query {
            let found = AccessibilityTargetResolver.candidates(roots: tree.roots, query: query, elementType: nil)
            let inputs = (found.viewport == nil ? found.matches : found.onScreen).filter { $0.role.isTextInput }
            if inputs.count == 1 { return inputs[0] }
            return field.flatMap { nearest(inputs, to: $0) }
        }
        guard let field else { return nil }
        if case .field(let focused) = TextFocus.read(tree) {
            return Self.isSameField(focused, field) ? focused : nil
        }
        return nearest(nodes.filter { Self.isSameField($0, field) }, to: field)
    }

    private func nearest(_ candidates: [UINode], to field: UINode) -> UINode? {
        guard let centre = field.frame?.center else { return candidates.count == 1 ? candidates.first : nil }
        return NodeIdentity.nearest(candidates.filter { $0.role == field.role }, to: centre)
    }

    /// The same input across reads: its id when it has one, else its label or where it sits, since its value is what changed.
    static func isSameField(_ lhs: UINode, _ rhs: UINode) -> Bool {
        guard lhs.role == rhs.role else { return false }
        if lhs.id != nil || rhs.id != nil { return lhs.id == rhs.id }
        if lhs.label != nil, lhs.label == rhs.label { return true }
        guard let one = lhs.frame, let other = rhs.frame else { return false }
        return one.intersection(other).map { $0.width * $0.height > 0 } ?? false
    }
}
