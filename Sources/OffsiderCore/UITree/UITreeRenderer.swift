import Foundation

/// A neutral node key that `--fields` can select, in schema order.
public enum UIField: String, CaseIterable, Sendable {
    case role, id, label, value, frame, enabled, state, native
}

public enum UITreeFormat: String, CaseIterable, Sendable {
    case json, ndjson, text
}

public struct UIFieldError: Error, Equatable, CustomStringConvertible {
    public let description: String
}

public struct UITreeRenderOptions: Equatable, Sendable {
    public var format: UITreeFormat
    public var flat: Bool
    public var filter: UITreeFilter
    /// Keys to print; nil prints every key (text leaves out `native` unless it is listed).
    public var fields: [UIField]?
    public var compact: Bool
    /// Text only: cut the output at whole lines to fit this many bytes; nil prints everything.
    public var maxBytes: Int?

    public init(
        format: UITreeFormat = .json,
        flat: Bool = false,
        filter: UITreeFilter = UITreeFilter(),
        fields: [UIField]? = nil,
        compact: Bool = false,
        maxBytes: Int? = nil
    ) {
        self.format = format
        self.flat = flat
        self.filter = filter
        self.fields = fields
        self.compact = compact
        self.maxBytes = maxBytes
    }

    /// The `--summary` byte budget.
    public static let summaryMaxBytes = 16384

    /// The short agent view: flat, on-screen, labelled, text.
    public static let summary = UITreeRenderOptions(
        format: .text,
        flat: true,
        filter: UITreeFilter(onScreen: true, labelled: true),
        maxBytes: summaryMaxBytes
    )

    /// Parses `role,label,...` into schema order without duplicates.
    public static func parseFields(_ csv: String) throws -> [UIField] {
        let names = csv
            .split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let known = UIField.allCases.map(\.rawValue).joined(separator: ", ")
        var selected = Set<UIField>()
        for name in names {
            guard let field = UIField(rawValue: name) else {
                throw UIFieldError(description: "Unknown field '\(name)' in --fields. Use: \(known).")
            }
            selected.insert(field)
        }
        return UIField.allCases.filter(selected.contains)
    }
}

public enum UITreeRenderer {
    /// Output for `describe-ui`, ending in a newline; default options give exactly `tree.jsonData()`.
    public static func render(_ tree: UITree, _ options: UITreeRenderOptions) -> Data {
        let fields = options.fields.map(Set.init)
        let output: String
        switch options.format {
        case .json:
            output = json(tree, options, fields: fields).rendered(compact: options.compact) + "\n"
        case .ndjson:
            let lines = [OrderedJSON.object(envelope(tree))]
                + tree.flatEntries(options.filter).map { flatJSON($0, fields: fields) }
            output = lines.map { $0.rendered(compact: true) + "\n" }.joined()
        case .text:
            output = text(tree, options, fields: fields)
        }
        return Data(output.utf8)
    }

    private static func envelope(_ tree: UITree) -> [(String, OrderedJSON)] {
        [
            ("version", .integer(UITree.schemaVersion)),
            ("platform", .string(tree.platform.rawValue)),
            ("device", .string(tree.device)),
            ("screen", tree.screen.map { $0.jsonValue(on: tree.platform) } ?? .null),
        ]
    }

    static func json(_ tree: UITree, _ options: UITreeRenderOptions, fields: Set<UIField>?) -> OrderedJSON {
        if options.flat {
            let nodes = tree.flatEntries(options.filter).map { flatJSON($0, fields: fields) }
            return .object(envelope(tree) + [("nodes", .array(nodes))])
        }
        let roots = tree.filtered(options.filter).roots.map { nestedJSON($0, fields: fields) }
        return .object(envelope(tree) + [("roots", .array(roots))])
    }

    private static func members(_ node: UINode, fields: Set<UIField>?) -> [(String, OrderedJSON)] {
        guard let fields else { return node.jsonFields }
        return node.jsonFields.filter { UIField(rawValue: $0.0).map(fields.contains) ?? false }
    }

    private static func nestedJSON(_ node: UINode, fields: Set<UIField>?) -> OrderedJSON {
        .object(members(node, fields: fields) + [("children", .array(node.children.map { nestedJSON($0, fields: fields) }))])
    }

    private static func flatJSON(_ entry: UIFlatEntry, fields: Set<UIField>?) -> OrderedJSON {
        .object([
            ("index", .integer(entry.index)),
            ("parent", .optional(entry.parent, OrderedJSON.integer)),
            ("depth", .integer(entry.depth)),
        ] + members(entry.node, fields: fields))
    }

    // MARK: Text

    private static func text(_ tree: UITree, _ options: UITreeRenderOptions, fields: Set<UIField>?) -> String {
        let shown = fields ?? Set(UIField.allCases).subtracting([.native])
        let result = UITreeEconomy.lines(tree, options, fields: shown) { node, label, value in
            line(node, shown, label: label, value: value)
        }
        return UITreeEconomy.budgeted(
            result.lines,
            header: header(tree),
            folded: result.folded,
            sourceTruncated: tree.sourceTruncated,
            maxBytes: options.maxBytes
        )
    }

    static func header(_ tree: UITree) -> String {
        var parts = ["#", tree.platform.rawValue, tree.device]
        if let screen = tree.screen {
            parts.append("\(number(screen.width))x\(number(screen.height))")
            if let scale = screen.scale {
                parts.append("@\(OrderedJSON.formatNumber(scale))x")
            }
            parts.append(screen.shape.rawValue + (screen.resolvedRotationDegrees.map { " \($0)°" } ?? ""))
            if let posture = screen.posture {
                parts.append("\(screen.resolvedDisplay(on: tree.platform).id) \(posture.rawValue)")
            }
        }
        return parts.joined(separator: " ")
    }

    /// One unfolded line, for callers that show a single node such as the diff renderer.
    static func line(_ node: UINode, _ fields: Set<UIField>) -> String {
        line(node, fields, label: fields.contains(.label) ? node.label : nil, value: fields.contains(.value) ? node.value : nil)
    }

    /// `label` and `value` arrive already folded, nil to leave them out.
    private static func line(_ node: UINode, _ fields: Set<UIField>, label: String?, value: String?) -> String {
        var parts = [node.role.rawValue]
        if let label = nonEmpty(label) {
            parts.append(quoted(label))
        }
        if fields.contains(.id), let id = nonEmpty(node.id) {
            parts.append("id=" + token(id))
        }
        if let value = nonEmpty(value) {
            parts.append("value=" + quoted(value))
        }
        if fields.contains(.native), let type = node.native.typeName.flatMap(nonEmpty) {
            parts.append("native=" + token(type))
        }
        if fields.contains(.frame) {
            parts.append(node.frame.map { "(\(number($0.x)),\(number($0.y)) \(number($0.width))x\(number($0.height)))" } ?? "(no frame)")
        }
        if fields.contains(.enabled), node.enabled == false {
            parts.append("disabled")
        }
        if fields.contains(.state) {
            if node.state.checked == true { parts.append("checked") }
            if node.state.selected == true { parts.append("selected") }
            if node.state.focused == true { parts.append("focused") }
        }
        return parts.joined(separator: " ")
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    static func quoted(_ value: String) -> String {
        var output = ""
        OrderedJSON.writeString(value, to: &output)
        return output
    }

    /// Bare when the value is a plain identifier, else JSON-quoted.
    static func token(_ value: String) -> String {
        let plain = value.unicodeScalars.allSatisfy { scalar in
            scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || "_.:/-".unicodeScalars.contains(scalar))
        }
        return plain ? value : quoted(value)
    }

    /// Whole numbers without a fraction, others rounded to one decimal place.
    static func number(_ value: Double) -> String {
        OrderedJSON.formatNumber((value * 10).rounded() / 10)
    }
}
