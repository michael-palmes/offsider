import Foundation

/// Compares two accessibility snapshots. Each node is keyed by its path of `type#identifier[n]`
/// components, with UUID-shaped identifier text normalised to `<uuid>` and `n` the ordinal among
/// siblings sharing that type and identifier. A shared key changes when its role, subrole, label,
/// value, title, enabled state or frame (rounded to `framePrecision`) differs. The result is
/// `changed` when the key sets or any shared signature differ outside the volatile keys, and
/// `unknown` when either snapshot has no children to compare.
public struct ChangeDetector: Sendable {
    public struct Options: Sendable {
        public var framePrecision: Double
        public var ignoredIdentifiers: Set<String>

        public init(framePrecision: Double = 1, ignoredIdentifiers: Set<String> = []) {
            self.framePrecision = framePrecision
            self.ignoredIdentifiers = ignoredIdentifiers
        }
    }

    public enum Result: Equatable, Sendable {
        case unknown
        case unchanged
        case changed(summary: String)
    }

    private struct Signature: Equatable {
        let role: String?
        let subrole: String?
        let label: String?
        let value: String?
        let title: String?
        let enabled: Bool?
        let frame: [Double]?
    }

    private struct Entry {
        let key: String
        let name: String
        let element: String
        let node: AccessibilitySnapshot.Node
        let signature: Signature
    }

    public let options: Options

    public init(options: Options = .init()) {
        self.options = options
    }

    public func volatileKeys(_ first: AccessibilitySnapshot, _ second: AccessibilitySnapshot) -> Set<String> {
        let a = Dictionary(uniqueKeysWithValues: entries(first).map { ($0.key, $0.signature) })
        let b = Dictionary(uniqueKeysWithValues: entries(second).map { ($0.key, $0.signature) })
        return Set(a.keys).symmetricDifference(b.keys)
            .union(a.keys.filter { key in b[key].map { $0 != a[key] } ?? false })
    }

    public func compare(
        _ before: AccessibilitySnapshot,
        _ after: AccessibilitySnapshot,
        ignoring volatile: Set<String> = []
    ) -> Result {
        guard before.isKnown, after.isKnown else { return .unknown }
        let beforeEntries = entries(before).filter { !volatile.contains($0.key) }
        let afterEntries = entries(after).filter { !volatile.contains($0.key) }
        let beforeByKey = Dictionary(uniqueKeysWithValues: beforeEntries.map { ($0.key, $0) })
        let afterKeys = Set(afterEntries.map(\.key))

        for entry in afterEntries {
            guard let previous = beforeByKey[entry.key] else {
                return .changed(summary: "element added: \(entry.element)")
            }
            if let difference = describeDifference(from: previous, to: entry) {
                return .changed(summary: difference)
            }
        }
        if let removed = beforeEntries.first(where: { !afterKeys.contains($0.key) }) {
            return .changed(summary: "element removed: \(removed.element)")
        }
        return .unchanged
    }

    private func entries(_ snapshot: AccessibilitySnapshot) -> [Entry] {
        var result: [Entry] = []
        flatten(snapshot.roots, parentKey: "", into: &result)
        return result
    }

    private func flatten(_ nodes: [AccessibilitySnapshot.Node], parentKey: String, into result: inout [Entry]) {
        var ordinals: [String: Int] = [:]
        for node in nodes {
            let identifier = Self.normalisedIdentifier(node.identifier)
            if let identifier, options.ignoredIdentifiers.contains(identifier) { continue }
            let component = "\(node.type)#\(identifier ?? "")"
            let ordinal = ordinals[component, default: 0]
            ordinals[component] = ordinal + 1
            let key = "\(parentKey)/\(component)[\(ordinal)]"
            result.append(Entry(
                key: key,
                name: Self.displayName(node, identifier: identifier),
                element: identifier.map { "\(node.type)#\($0)" } ?? Self.displayName(node, identifier: nil),
                node: node,
                signature: signature(node)
            ))
            flatten(node.children, parentKey: key, into: &result)
        }
    }

    private func signature(_ node: AccessibilitySnapshot.Node) -> Signature {
        let precision = options.framePrecision > 0 ? options.framePrecision : 1
        let frame = node.frame.map { frame in
            [frame.x, frame.y, frame.width, frame.height].map { ($0 / precision).rounded() }
        }
        return Signature(
            role: node.role,
            subrole: node.subrole,
            label: node.label,
            value: node.value,
            title: node.title,
            enabled: node.enabled,
            frame: frame
        )
    }

    private func describeDifference(from before: Entry, to after: Entry) -> String? {
        let a = before.signature
        let b = after.signature
        let name = after.name
        if a.value != b.value { return "value of \(name) changed from \(Self.quoted(a.value)) to \(Self.quoted(b.value))" }
        if a.label != b.label { return "label of \(name) changed from \(Self.quoted(a.label)) to \(Self.quoted(b.label))" }
        if a.title != b.title { return "title of \(name) changed from \(Self.quoted(a.title)) to \(Self.quoted(b.title))" }
        if a.enabled != b.enabled { return "\(name) became \(b.enabled == true ? "enabled" : "disabled")" }
        if a.frame != b.frame { return "\(name) moved or resized" }
        if a.role != b.role || a.subrole != b.subrole { return "role of \(name) changed" }
        return nil
    }

    private static func displayName(_ node: AccessibilitySnapshot.Node, identifier: String?) -> String {
        if let identifier { return identifier }
        if let label = node.label?.trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty {
            return "\(node.type) \"\(label)\""
        }
        return node.type
    }

    private static func quoted(_ value: String?) -> String {
        value.map { "\"\($0)\"" } ?? "nothing"
    }

    static func normalisedIdentifier(_ identifier: String?) -> String? {
        guard let trimmed = identifier?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        let range = NSRange(trimmed.startIndex..., in: trimmed)
        return uuidPattern.stringByReplacingMatches(in: trimmed, range: range, withTemplate: "<uuid>")
    }

    private static let uuidPattern = try! NSRegularExpression(
        pattern: "[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}"
    )
}
