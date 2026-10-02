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

    public init(
        format: UITreeFormat = .json,
        flat: Bool = false,
        filter: UITreeFilter = UITreeFilter(),
        fields: [UIField]? = nil,
        compact: Bool = false
    ) {
        self.format = format
        self.flat = flat
        self.filter = filter
        self.fields = fields
        self.compact = compact
    }

    /// The short agent view: flat, on-screen, labelled, text.
    public static let summary = UITreeRenderOptions(
        format: .text,
        flat: true,
        filter: UITreeFilter(onScreen: true, labelled: true)
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
            ("screen", tree.screen.map(\.jsonValue) ?? .null),
        ]
    }

    private static func json(_ tree: UITree, _ options: UITreeRenderOptions, fields: Set<UIField>?) -> OrderedJSON {
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
        let entries = options.flat
            ? tree.flatEntries(options.filter)
            : tree.filtered(options.filter).flatEntries(UITreeFilter())
        let shown = fields ?? Set(UIField.allCases).subtracting([.native])
        var depths: [Int] = []
        var output = header(tree) + "\n"
        for entry in entries {
            let depth = entry.parent.map { depths[$0] + 1 } ?? 0
            depths.append(depth)
            output += String(repeating: "  ", count: depth) + line(entry.node, shown) + "\n"
        }
        return output
    }

    private static func header(_ tree: UITree) -> String {
        var parts = ["#", tree.platform.rawValue, tree.device]
        if let screen = tree.screen {
            parts.append("\(number(screen.width))x\(number(screen.height))")
            if let scale = screen.scale {
                parts.append("@\(OrderedJSON.formatNumber(scale))x")
            }
            if let orientation = screen.orientation {
                parts.append(orientation.rawValue)
            }
        }
        return parts.joined(separator: " ")
    }

    private static func line(_ node: UINode, _ fields: Set<UIField>) -> String {
        var parts = [node.role.rawValue]
        if fields.contains(.label), let label = nonEmpty(node.label) {
            parts.append(quoted(label))
        }
        if fields.contains(.id), let id = nonEmpty(node.id) {
            parts.append("id=" + token(id))
        }
        if fields.contains(.value), let value = nonEmpty(node.value) {
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

    private static func quoted(_ value: String) -> String {
        var output = ""
        OrderedJSON.writeString(value, to: &output)
        return output
    }

    /// Bare when the value is a plain identifier, else JSON-quoted.
    private static func token(_ value: String) -> String {
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
