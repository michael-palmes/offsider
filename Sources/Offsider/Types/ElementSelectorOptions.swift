import ArgumentParser
import Foundation
import OffsiderCore

/// The `--id`/`--label`/`--label-contains`/`--value` selector rules shared by `tap`, `slider`, `type`, `wait` and `assert`.
enum SelectorQuery {
    static let refinementRule = "Use one of --id, --label, --label-contains or --value, or narrow one --id with a --label or --label-contains, a --value or both, which must all match one element."
    static let oneLabelRule = "Use only one of --label or --label-contains."

    /// Rejects more than one selector, unless `refining` lets `--label` (or `--label-contains`) and `--value` narrow an `--id`, and an empty one; setting none is left to the caller.
    static func validate(id: String?, label: String?, labelContains: String? = nil, value: String?, refining: Bool = false) throws {
        if label != nil, labelContains != nil { throw ValidationError(oneLabelRule) }
        let selectors = [("--id", id), ("--label", label), ("--label-contains", labelContains), ("--value", value)].filter { $0.1 != nil }
        if selectors.count > 1 {
            guard refining else { throw ValidationError("Use only one of --id, --label, --label-contains or --value.") }
            guard id != nil else { throw ValidationError(refinementRule) }
        }
        for (name, text) in selectors where text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true {
            throw ValidationError("\(name) must not be empty.")
        }
    }

    /// `wait --any` takes several selectors; every other command takes one.
    static func validate(ids: [String], labels: [String], labelsContaining: [String] = [], values: [String], allowingSeveral: Bool) throws {
        let named = ids.map { ("--id", $0) } + labels.map { ("--label", $0) } + labelsContaining.map { ("--label-contains", $0) } + values.map { ("--value", $0) }
        if named.count > 1 && !allowingSeveral {
            throw ValidationError("Use only one of --id, --label, --label-contains or --value.")
        }
        for (name, text) in named where text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw ValidationError("\(name) must not be empty.")
        }
    }

    static func make(id: String?, label: String?, labelContains: String? = nil, value: String?) -> AccessibilityQuery? {
        let labelQuery = label.map(AccessibilityQuery.label) ?? labelContains.map(AccessibilityQuery.labelContains)
        if let id {
            let refinements = [labelQuery, value.map(AccessibilityQuery.value)].compactMap { $0 }
            return refinements.isEmpty ? .id(id) : .all(.id(id), refinedBy: refinements)
        }
        if let labelQuery { return labelQuery }
        if let value { return .value(value) }
        return nil
    }

    /// Names the elements closest to `query` once a wait or assert ends with nothing matching it.
    static func explain(_ query: AccessibilityQuery) -> (UITree) -> WaitNearMiss? {
        { tree in AccessibilityTargetResolver.nearMiss(roots: tree.roots, query: query) }
    }
}

/// One element selector for commands that check state rather than tap: `wait` and `assert`.
struct ElementSelectorOptions: ParsableArguments {
    @Option(name: [.customLong("id")], help: "The element whose describe-ui id matches (accessibilityIdentifier, or testID in React Native); repeat with wait --any.")
    var elementIDs: [String] = []

    @Option(name: [.customLong("label")], help: "The element whose describe-ui label matches (accessibilityLabel); repeat with wait --any.")
    var elementLabels: [String] = []

    @Option(name: [.customLong("label-contains")], help: ArgumentHelp("The element whose describe-ui label holds this text, in the same case, such as one part of a label React Native merged; repeat with wait --any.", valueName: "text"))
    var elementLabelsContaining: [String] = []

    @Option(name: [.customLong("value")], help: "The element whose describe-ui value matches (the current value of a control); repeat with wait --any.")
    var elementValues: [String] = []

    @Option(name: [.customLong("element-type")], help: "Filter matches to this describe-ui role in any case (e.g. button, textField, switch) or exact native type (e.g. TextEditor).")
    var elementType: String?

    @Option(name: [.customLong("has-value")], help: ArgumentHelp("Also require the element's value to equal this text.", valueName: "text"))
    var hasValue: String?

    @Flag(name: .customLong("enabled"), help: "Also require the element to be enabled.")
    var enabled = false

    @Flag(name: .customLong("disabled"), help: "Also require the element to be disabled, as a button is until its form is filled.")
    var disabled = false

    @Flag(name: .customLong("allow-offscreen"), help: "Count elements whose frame is outside the screen (off by default: only on-screen matches count).")
    var allowOffscreen: Bool = false

    /// `--enabled` is true, `--disabled` false, neither nil.
    var requiredEnabled: Bool? { enabled ? true : disabled ? false : nil }

    /// The count is left to the command, since only `wait --any` takes several, and one `--id` narrowed by a label or value counts as one.
    func validate() throws {
        try SelectorQuery.validate(ids: elementIDs, labels: elementLabels, labelsContaining: elementLabelsContaining, values: elementValues, allowingSeveral: true)
        if enabled && disabled { throw ValidationError("Use only one of --enabled or --disabled.") }
        guard query == nil else { return }
        for (name, isSet) in [("--element-type", elementType != nil), ("--has-value", hasValue != nil), ("--enabled", enabled), ("--disabled", disabled), ("--allow-offscreen", allowOffscreen)] where isSet {
            throw ValidationError("\(name) needs --id, --label, --label-contains or --value.")
        }
    }

    /// The selector outside `wait --any`: the only one, or an `--id` with the `--label` and `--value` that narrow it.
    var query: AccessibilityQuery? {
        guard isConjunction else { return queries.first }
        return .all(.id(elementIDs[0]), refinedBy: labelQueries + elementValues.map(AccessibilityQuery.value))
    }

    /// One `--id` with at most one `--label` or `--label-contains` and one `--value`, all of which one element must match.
    var isConjunction: Bool {
        elementIDs.count == 1 && labelQueries.count <= 1 && elementValues.count <= 1 && !(labelQueries.isEmpty && elementValues.isEmpty)
    }

    /// Every selector, ids then labels then values.
    var queries: [AccessibilityQuery] {
        elementIDs.map(AccessibilityQuery.id) + labelQueries + elementValues.map(AccessibilityQuery.value)
    }

    private var labelQueries: [AccessibilityQuery] {
        elementLabels.map(AccessibilityQuery.label) + elementLabelsContaining.map(AccessibilityQuery.labelContains)
    }

    /// Outside `wait --any`, `--label` and `--label-contains` both read the label, so only one may be given.
    var mixesLabelSelectors: Bool {
        !elementLabels.isEmpty && !elementLabelsContaining.isEmpty
    }

    func validateCount(allowingSeveral: Bool) throws {
        if !allowingSeveral, mixesLabelSelectors {
            throw ValidationError(SelectorQuery.oneLabelRule)
        }
        if !allowingSeveral, queries.count > 1, !isConjunction {
            throw ValidationError(SelectorQuery.refinementRule)
        }
        try SelectorQuery.validate(ids: elementIDs, labels: elementLabels, labelsContaining: elementLabelsContaining, values: elementValues, allowingSeveral: true)
    }

    /// Present when a qualifying candidate exists, even several; on-screen only unless `--allow-offscreen` or the tree has no screen.
    func probe(for query: AccessibilityQuery) -> (UITree) -> ElementProbe {
        let elementType = elementType
        let allowOffscreen = allowOffscreen
        let hasValue = hasValue
        let requiredEnabled = requiredEnabled
        return { tree in
            let found = AccessibilityTargetResolver.candidates(roots: tree.roots, query: query, elementType: elementType)
            var read: LogBoxInspector??
            func inspector() -> LogBoxInspector? {
                if let read { return read }
                let inspector = KnownOverlays.logBoxInspector(in: tree.roots, viewport: tree.viewport)
                read = .some(inspector)
                return inspector
            }
            func absent(_ reason: String) -> ElementProbe {
                guard inspector() != nil else { return .absent(reason: reason) }
                return .absent(reason: reason + "; LogBox inspector open")
            }
            guard let first = found.matches.first else {
                if let block = LogBoxBlock.hiding(tree, inspector: inspector(), subject: query.selectorDescription) {
                    return .blocked(block)
                }
                return absent("not found")
            }
            var pool = allowOffscreen || found.viewport == nil ? found.matches : found.onScreen
            guard !pool.isEmpty else {
                let place = first.hasPositiveFrame ? first.frame.map { "off screen at \($0.summary)" } : nil
                let more = found.matches.count > 1 ? " (and \(found.matches.count - 1) more)" : ""
                return absent((place ?? "has no usable frame") + more)
            }
            if !allowOffscreen, let front = tree.front, !front.isEmpty {
                let reasons = pool.map { front.reason(for: $0, in: tree.roots) }
                let reached = zip(pool, reasons).filter { $0.1 == nil }.map(\.0)
                guard !reached.isEmpty else {
                    let more = pool.count > 1 ? " (and \(pool.count - 1) more)" : ""
                    return absent("\(reasons[0] ?? "covered")\(more), so a tap would not reach it")
                }
                pool = reached
            }
            if let hasValue {
                let valued = pool.filter { Self.value(of: $0, equals: hasValue) }
                guard !valued.isEmpty else {
                    let hidden = OutputMasks.current.mask.hidesValue(of: pool[0])
                    let actual = pool[0].normalizedValue.map { hidden ? "has a masked value" : "has value '\(LogRedactor.redactValue(TerminalText.line($0, keepsTab: false)).text)'" } ?? "has no value"
                    let labelled = pool.contains { AccessibilityQuery.label(hasValue).matches($0) }
                    let hint = labelled ? "; '\(hasValue)' is its label: use --label '\(hasValue)'" : ""
                    return absent("\(actual), expected '\(hasValue)'\(hint)")
                }
                pool = valued
            }
            pool = Self.controls(pool).map { Self.withEnabledState($0, in: tree.roots) }
            if let requiredEnabled {
                let held = pool.filter { $0.enabled == requiredEnabled }
                guard !held.isEmpty else {
                    let wanted = requiredEnabled ? "enabled" : "disabled"
                    return absent(pool[0].enabled == nil ? "does not say whether it is enabled, expected \(wanted)" : "is \(requiredEnabled ? "disabled" : "enabled"), expected \(wanted)")
                }
                pool = held
            }
            return .present(pool.count == 1 ? pool[0] : nil)
        }
    }

    /// The control among several matches, as a tap chooses: an actionable match over plain text, then of those nested in each other the deepest, which a touch reaches; with no control, the outermost.
    private static func controls(_ pool: [UINode]) -> [UINode] {
        guard pool.count > 1 else { return pool }
        let actionable = pool.filter(\.isActionable)
        func holds(_ outer: UINode, _ inner: UINode) -> Bool { outer.flattened().dropFirst().contains { $0.isSameElement(as: inner) } }
        guard actionable.isEmpty else {
            return actionable.filter { node in !actionable.contains { holds(node, $0) } }
        }
        return pool.filter { node in !pool.contains { holds($0, node) } }
    }

    /// Plain text reads disabled inside a disabled control, since a touch on it goes to that control; a control answers for itself.
    private static func withEnabledState(_ node: UINode, in roots: [UINode]) -> UINode {
        guard !node.isActionable, node.enabled != false,
              AccessibilityTargetResolver.ancestorsOf(node, in: roots).contains(where: { $0.isActionable && $0.enabled == false }) else { return node }
        var disabled = node
        disabled.enabled = false
        return disabled
    }

    /// Exact after trimming, then after folding quotes and spaces.
    static func value(of node: UINode, equals expected: String) -> Bool {
        let wanted = expected.trimmingCharacters(in: .whitespacesAndNewlines)
        let actual = node.normalizedValue ?? ""
        return actual == wanted || SelectorText.folded(actual) == SelectorText.folded(wanted)
    }

    /// "on screen", "present" with --allow-offscreen, plus "with value 'X'" for --has-value and "and enabled" or "and disabled".
    var presentState: String {
        let place = allowOffscreen ? "present" : "on screen"
        let valued = hasValue.map { "\(place) with value '\($0)'" } ?? place
        return requiredEnabled.map { "\(valued) and \($0 ? "enabled" : "disabled")" } ?? valued
    }

    /// `source` with the shared on-screen judgement read for the on-screen matches of `queries`, so a match a touch would not reach does not count; unchanged with `--allow-offscreen`.
    @MainActor
    func judging(_ source: @escaping Wait.TreeSource, queries: [AccessibilityQuery], on route: DeviceRouter.Route) -> Wait.TreeSource {
        guard !allowOffscreen, !queries.isEmpty else { return source }
        let elementType = elementType
        return {
            var tree = try await source()
            await FrontJudge.read(matching: queries, elementType: elementType, in: &tree, backend: route.backend, device: route.device)
            return tree
        }
    }
}
