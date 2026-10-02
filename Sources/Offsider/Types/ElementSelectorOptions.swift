import ArgumentParser
import Foundation
import OffsiderCore

/// One element selector for commands that check state rather than tap: `wait` and `assert`.
struct ElementSelectorOptions: ParsableArguments {
    @Option(name: [.customLong("id")], help: "The element whose describe-ui id matches (accessibilityIdentifier, or testID in React Native).")
    var elementID: String?

    @Option(name: [.customLong("label")], help: "The element whose describe-ui label matches (accessibilityLabel).")
    var elementLabel: String?

    @Option(name: [.customLong("value")], help: "The element whose describe-ui value matches (the current value of a control).")
    var elementValue: String?

    @Option(name: [.customLong("element-type")], help: "Filter matches to this describe-ui role in any case (e.g. button, textField, switch) or exact native type (e.g. TextEditor).")
    var elementType: String?

    @Option(name: [.customLong("has-value")], help: ArgumentHelp("Also require the element's value to equal this text.", valueName: "text"))
    var hasValue: String?

    @Flag(name: .customLong("allow-offscreen"), help: "Count elements whose frame is outside the screen (off by default: only on-screen matches count).")
    var allowOffscreen: Bool = false

    func validate() throws {
        let selectors = [("--id", elementID), ("--label", elementLabel), ("--value", elementValue)].filter { $0.1 != nil }
        if selectors.count > 1 {
            throw ValidationError("Use only one of --id, --label, or --value.")
        }
        for (name, value) in selectors where value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true {
            throw ValidationError("\(name) must not be empty.")
        }
        guard selectors.isEmpty else { return }
        for (name, isSet) in [("--element-type", elementType != nil), ("--has-value", hasValue != nil), ("--allow-offscreen", allowOffscreen)] where isSet {
            throw ValidationError("\(name) needs --id, --label or --value.")
        }
    }

    var query: AccessibilityQuery? {
        if let elementID { return .id(elementID) }
        if let elementLabel { return .label(elementLabel) }
        if let elementValue { return .value(elementValue) }
        return nil
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
                let place = first.frame.map { "off screen at \($0.summary)" } ?? "off screen with no frame"
                let more = found.matches.count > 1 ? " (and \(found.matches.count - 1) more)" : ""
                return .absent(reason: place + more)
            }
            if let hasValue {
                let valued = pool.filter { Self.value(of: $0, equals: hasValue) }
                guard !valued.isEmpty else {
                    let actual = pool[0].normalizedValue.map { "has value '\($0)'" } ?? "has no value"
                    return .absent(reason: "\(actual), expected '\(hasValue)'")
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
