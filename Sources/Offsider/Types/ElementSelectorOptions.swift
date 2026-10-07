import ArgumentParser
import Foundation
import OffsiderCore

/// The `--id`/`--label`/`--value` selector rules shared by `tap`, `slider`, `wait` and `assert`.
enum SelectorQuery {
    static let refinementRule = "Use one of --id, --label or --value, or narrow one --id with a --label, a --value or both, which must all match one element."

    /// Rejects more than one selector, unless `refining` lets `--label` and `--value` narrow an `--id`, and an empty one; setting none is left to the caller.
    static func validate(id: String?, label: String?, value: String?, refining: Bool = false) throws {
        let selectors = [("--id", id), ("--label", label), ("--value", value)].filter { $0.1 != nil }
        if selectors.count > 1 {
            guard refining else { throw ValidationError("Use only one of --id, --label, or --value.") }
            guard id != nil else { throw ValidationError(refinementRule) }
        }
        for (name, text) in selectors where text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true {
            throw ValidationError("\(name) must not be empty.")
        }
    }

    /// `wait --any` takes several selectors; every other command takes one.
    static func validate(ids: [String], labels: [String], values: [String], allowingSeveral: Bool) throws {
        let named = ids.map { ("--id", $0) } + labels.map { ("--label", $0) } + values.map { ("--value", $0) }
        if named.count > 1 && !allowingSeveral {
            throw ValidationError("Use only one of --id, --label, or --value.")
        }
        for (name, text) in named where text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw ValidationError("\(name) must not be empty.")
        }
    }

    static func make(id: String?, label: String?, value: String?) -> AccessibilityQuery? {
        if let id {
            let refinements = [label.map(AccessibilityQuery.label), value.map(AccessibilityQuery.value)].compactMap { $0 }
            return refinements.isEmpty ? .id(id) : .all(.id(id), refinedBy: refinements)
        }
        if let label { return .label(label) }
        if let value { return .value(value) }
        return nil
    }
}

/// One element selector for commands that check state rather than tap: `wait` and `assert`.
struct ElementSelectorOptions: ParsableArguments {
    @Option(name: [.customLong("id")], help: "The element whose describe-ui id matches (accessibilityIdentifier, or testID in React Native); repeat with wait --any.")
    var elementIDs: [String] = []

    @Option(name: [.customLong("label")], help: "The element whose describe-ui label matches (accessibilityLabel); repeat with wait --any.")
    var elementLabels: [String] = []

    @Option(name: [.customLong("value")], help: "The element whose describe-ui value matches (the current value of a control); repeat with wait --any.")
    var elementValues: [String] = []

    @Option(name: [.customLong("element-type")], help: "Filter matches to this describe-ui role in any case (e.g. button, textField, switch) or exact native type (e.g. TextEditor).")
    var elementType: String?

    @Option(name: [.customLong("has-value")], help: ArgumentHelp("Also require the element's value to equal this text.", valueName: "text"))
    var hasValue: String?

    @Flag(name: .customLong("allow-offscreen"), help: "Count elements whose frame is outside the screen (off by default: only on-screen matches count).")
    var allowOffscreen: Bool = false

    /// The count is left to the command, since only `wait --any` takes several, and one `--id` narrowed by a label or value counts as one.
    func validate() throws {
        try SelectorQuery.validate(ids: elementIDs, labels: elementLabels, values: elementValues, allowingSeveral: true)
        guard query == nil else { return }
        for (name, isSet) in [("--element-type", elementType != nil), ("--has-value", hasValue != nil), ("--allow-offscreen", allowOffscreen)] where isSet {
            throw ValidationError("\(name) needs --id, --label or --value.")
        }
    }

    /// The selector outside `wait --any`: the only one, or an `--id` with the `--label` and `--value` that narrow it.
    var query: AccessibilityQuery? {
        guard isConjunction else { return queries.first }
        return .all(.id(elementIDs[0]), refinedBy: elementLabels.map(AccessibilityQuery.label) + elementValues.map(AccessibilityQuery.value))
    }

    /// One `--id` with at most one `--label` and one `--value`, all of which one element must match.
    var isConjunction: Bool {
        elementIDs.count == 1 && elementLabels.count <= 1 && elementValues.count <= 1 && !(elementLabels.isEmpty && elementValues.isEmpty)
    }

    /// Every selector, ids then labels then values.
    var queries: [AccessibilityQuery] {
        elementIDs.map(AccessibilityQuery.id) + elementLabels.map(AccessibilityQuery.label) + elementValues.map(AccessibilityQuery.value)
    }

    func validateCount(allowingSeveral: Bool) throws {
        if !allowingSeveral, queries.count > 1, !isConjunction {
            throw ValidationError(SelectorQuery.refinementRule)
        }
        try SelectorQuery.validate(ids: elementIDs, labels: elementLabels, values: elementValues, allowingSeveral: true)
    }

    /// Present when a qualifying candidate exists, even several; on-screen only unless `--allow-offscreen` or the tree has no screen.
    func probe(for query: AccessibilityQuery) -> (UITree) -> ElementProbe {
        let elementType = elementType
        let allowOffscreen = allowOffscreen
        let hasValue = hasValue
        return { tree in
            let found = AccessibilityTargetResolver.candidates(roots: tree.roots, query: query, elementType: elementType)
            guard let first = found.matches.first else {
                return .absent(reason: "not found")
            }
            var pool = allowOffscreen || found.viewport == nil ? found.matches : found.onScreen
            guard !pool.isEmpty else {
                let place = first.hasPositiveFrame ? first.frame.map { "off screen at \($0.summary)" } : nil
                let more = found.matches.count > 1 ? " (and \(found.matches.count - 1) more)" : ""
                return .absent(reason: (place ?? "has no usable frame") + more)
            }
            if let hasValue {
                let valued = pool.filter { Self.value(of: $0, equals: hasValue) }
                guard !valued.isEmpty else {
                    let actual = pool[0].normalizedValue.map { "has value '\($0)'" } ?? "has no value"
                    let labelled = pool.contains { AccessibilityQuery.label(hasValue).matches($0) }
                    let hint = labelled ? "; '\(hasValue)' is its label: use --label '\(hasValue)'" : ""
                    return .absent(reason: "\(actual), expected '\(hasValue)'\(hint)")
                }
                pool = valued
            }
            return .present(pool.count == 1 ? pool[0] : nil)
        }
    }

    /// Exact after trimming, then after folding quotes and spaces.
    static func value(of node: UINode, equals expected: String) -> Bool {
        let wanted = expected.trimmingCharacters(in: .whitespacesAndNewlines)
        let actual = node.normalizedValue ?? ""
        return actual == wanted || SelectorText.folded(actual) == SelectorText.folded(wanted)
    }

    /// "on screen", "present" with --allow-offscreen, plus "with value 'X'" for --has-value.
    var presentState: String {
        let place = allowOffscreen ? "present" : "on screen"
        return hasValue.map { "\(place) with value '\($0)'" } ?? place
    }
}
