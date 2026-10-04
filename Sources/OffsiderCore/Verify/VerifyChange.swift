import Foundation

/// One node difference a verified command caused, for `--verify --json`.
public struct VerifyChange: Equatable, Sendable {
    public enum Kind: String, Sendable {
        case added, removed, changed
    }

    public let kind: Kind
    /// `role "label" id=x`, without the frame.
    public let node: String
    /// For `changed`: value, label, checked, selected, enabled or frame.
    public let field: String?
    public let old: String?
    public let new: String?

    public init(kind: Kind, node: String, field: String? = nil, old: String? = nil, new: String? = nil) {
        self.kind = kind
        self.node = node
        self.field = field
        self.old = old
        self.new = new
    }

    var jsonValue: OrderedJSON {
        .object([
            ("kind", .string(kind.rawValue)),
            ("node", .string(node)),
            ("field", .optional(field, OrderedJSON.string)),
            ("old", .optional(old, OrderedJSON.string)),
            ("new", .optional(new, OrderedJSON.string)),
        ])
    }
}

public enum VerifyNote: String, Sendable {
    /// Only the keyboard left; the input may have been spent closing it.
    case keyboardClosed = "keyboard_closed"
}

extension TreeDiff {
    public static let changeLimit = 10

    /// Value and state changes first, then added, then removed, then frame-only moves, each in document order; at most `limit`, with how many were left out.
    public func cappedChanges(limit: Int = TreeDiff.changeLimit) -> (changes: [VerifyChange], truncated: Int) {
        var fieldChanges: [VerifyChange] = []
        var added: [VerifyChange] = []
        var removed: [VerifyChange] = []
        var moved: [VerifyChange] = []
        for entry in entries {
            let name = Self.changeName(entry.line.node)
            switch entry.kind {
            case .added:
                added.append(VerifyChange(kind: .added, node: name))
            case .removed:
                removed.append(VerifyChange(kind: .removed, node: name))
            case .changed:
                guard let previous = entry.previous?.node else { continue }
                let fields = Self.fieldChanges(from: previous, to: entry.line.node)
                if fields.isEmpty {
                    if previous.frame != entry.line.node.frame {
                        moved.append(VerifyChange(
                            kind: .changed, node: name, field: "frame",
                            old: previous.frame?.summary, new: entry.line.node.frame?.summary
                        ))
                    }
                } else {
                    fieldChanges += fields.map { VerifyChange(kind: .changed, node: name, field: $0.0, old: $0.1, new: $0.2) }
                }
            }
        }
        let all = fieldChanges + added + removed + moved
        return (Array(all.prefix(limit)), max(0, all.count - limit))
    }

    /// The keyboard was in the old read, is gone from an untruncated new one, and nothing outside it changed except frames.
    public func keyboardOnlyClosed(old: UITree, new: UITree) -> Bool {
        guard !new.sourceTruncated, Self.hasKeyboard(old.roots), !Self.hasKeyboard(new.roots) else { return false }
        return entries.allSatisfy { entry in
            switch entry.kind {
            case .removed:
                return entry.line.underKeyboard
            case .added:
                return false
            case .changed:
                guard let previous = entry.previous?.node else { return false }
                return Self.fieldChanges(from: previous, to: entry.line.node).isEmpty
            }
        }
    }

    private static func hasKeyboard(_ roots: [UINode]) -> Bool {
        roots.contains { $0.flattened().contains { $0.role == .keyboard } }
    }

    private static func fieldChanges(from old: UINode, to new: UINode) -> [(String, String?, String?)] {
        var changes: [(String, String?, String?)] = []
        func add(_ field: String, _ lhs: String?, _ rhs: String?) {
            if lhs != rhs { changes.append((field, lhs.map { SelectorText.truncated($0) }, rhs.map { SelectorText.truncated($0) })) }
        }
        add("value", old.value, new.value)
        add("label", old.label, new.label)
        add("checked", old.state.checked.map(String.init), new.state.checked.map(String.init))
        add("selected", old.state.selected.map(String.init), new.state.selected.map(String.init))
        add("enabled", old.enabled.map(String.init), new.enabled.map(String.init))
        return changes
    }

    private static func changeName(_ node: UINode) -> String {
        var parts = [node.role.rawValue]
        if let label = node.label, !label.isEmpty {
            var quoted = ""
            OrderedJSON.writeString(SelectorText.truncated(label), to: &quoted)
            parts.append(quoted)
        }
        if let id = node.id, !id.isEmpty {
            parts.append("id=" + SelectorText.truncated(id))
        }
        return parts.joined(separator: " ")
    }
}
