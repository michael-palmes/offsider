import Foundation

/// Compares two accessibility snapshots. Each node is keyed by its path of `type#identifier[n]`
/// components, with UUID-shaped identifier text normalised to `<uuid>` and `n` the ordinal among
/// siblings sharing that type and identifier. A shared key changes when its role, subrole, label,
/// value, title, enabled, checked, selected or focused state, or frame (rounded to `framePrecision`)
/// differs. The result is `changed` when the key sets or any shared signature differ outside the
/// volatile keys, and `unknown` when either snapshot has no children to compare. Live keys (`role#identifier[n]`) line a cached tree up with a fresh read, sibling by sibling.
public struct ChangeDetector: Sendable {
    public struct Options: Sendable {
        public var framePrecision: Double
        public var ignoredIdentifiers: Set<String>
        /// Leaves label, value and title out, and the frame of a node whose text changed, so a ticking clock is no change.
        public var ignoreText: Bool
        /// Leaves frames out, so a moving list is no change.
        public var ignoreFrames: Bool

        public init(framePrecision: Double = 1, ignoredIdentifiers: Set<String> = [], ignoreText: Bool = false, ignoreFrames: Bool = false) {
            self.framePrecision = framePrecision
            self.ignoredIdentifiers = ignoredIdentifiers
            self.ignoreText = ignoreText
            self.ignoreFrames = ignoreFrames
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
        let state: UIState
        let frame: [Double]?

        /// Without text and frame, for a live key.
        var structural: Signature {
            Signature(role: role, subrole: subrole, label: nil, value: nil, title: nil, enabled: enabled, state: state, frame: nil)
        }
    }

    private struct Entry {
        let key: String
        let liveKey: String
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

    /// The live keys of every node, as `liveTextKeys` and `compare(live:)` name them.
    public func liveKeys(_ snapshot: AccessibilitySnapshot) -> Set<String> {
        Set(entries(snapshot).map(\.liveKey))
    }

    /// The share of live keys two reads have in common, from 0 to 1; 1 when both are empty.
    public func sharedKeyFraction(_ first: AccessibilitySnapshot, _ second: AccessibilitySnapshot) -> Double {
        let a = liveKeys(first)
        let b = liveKeys(second)
        guard let larger = [a.count, b.count].max(), larger > 0 else { return 1 }
        return Double(a.intersection(b).count) / Double(larger)
    }

    /// Live keys whose label, value or title differ, whatever the text options say; siblings are lined up by role and id, and each key is the second read's.
    public func liveTextKeys(_ first: AccessibilitySnapshot, _ second: AccessibilitySnapshot) -> Set<String> {
        var keys = Set<String>()
        func visit(_ old: [AccessibilitySnapshot.Node], _ new: [AccessibilitySnapshot.Node], parentKey: String) {
            let before = liveSiblings(old, parentKey: parentKey)
            let after = liveSiblings(new, parentKey: parentKey)
            // An added or removed row pairs with nothing, so neither the rows around it nor their later keys are taken for one another.
            let pairs = Self.alignment(before.map(\.component), after.map(\.component)) { Self.sameText(before[$0].node, after[$1].node) }
            for (index, otherIndex) in pairs {
                let (previous, current) = (before[index], after[otherIndex])
                if !Self.sameText(previous.node, current.node) {
                    keys.insert(current.key)
                }
                visit(previous.node.children, current.node.children, parentKey: current.key)
            }
        }
        visit(first.roots, second.roots, parentKey: "")
        return keys
    }

    private static func sameText(_ a: AccessibilitySnapshot.Node, _ b: AccessibilitySnapshot.Node) -> Bool {
        a.label == b.label && a.value == b.value && a.title == b.title
    }

    /// Past this many cells, two sibling lists that differ are not lined up, so nothing beneath them is learnt.
    static let maximumAlignmentCells = 1_000_000

    /// Index pairs of a longest common subsequence of `a` and `b`, choosing among equally long ones the most pairs with `unchanged` text.
    static func alignment(_ a: [String], _ b: [String], unchanged: (Int, Int) -> Bool) -> [(Int, Int)] {
        if a == b {
            return a.indices.map { ($0, $0) }
        }
        var start = 0
        while start < a.count, start < b.count, a[start] == b[start], unchanged(start, start) {
            start += 1
        }
        var (endA, endB) = (a.count, b.count)
        while endA > start, endB > start, a[endA - 1] == b[endB - 1], unchanged(endA - 1, endB - 1) {
            (endA, endB) = (endA - 1, endB - 1)
        }
        let (rows, columns) = (endA - start, endB - start)
        let prefix = (0..<start).map { ($0, $0) }
        let suffix = (0..<(a.count - endA)).map { (endA + $0, endB + $0) }
        guard rows > 0, columns > 0 else { return prefix + suffix }
        guard rows * columns <= maximumAlignmentCells else { return [] }
        // One more pair outweighs any number of unchanged texts.
        let pairWeight = min(rows, columns) + 1
        func gain(_ row: Int, _ column: Int) -> Int? {
            guard a[start + row] == b[start + column] else { return nil }
            return pairWeight + (unchanged(start + row, start + column) ? 1 : 0)
        }
        let width = columns + 1
        var best = [Int](repeating: 0, count: (rows + 1) * width)
        for row in stride(from: rows - 1, through: 0, by: -1) {
            for column in stride(from: columns - 1, through: 0, by: -1) {
                let skip = max(best[(row + 1) * width + column], best[row * width + column + 1])
                best[row * width + column] = gain(row, column).map { max(skip, best[(row + 1) * width + column + 1] + $0) } ?? skip
            }
        }
        var middle: [(Int, Int)] = []
        var (row, column) = (0, 0)
        while row < rows, column < columns {
            if let gain = gain(row, column), best[row * width + column] == best[(row + 1) * width + column + 1] + gain {
                middle.append((start + row, start + column))
                (row, column) = (row + 1, column + 1)
            } else if best[(row + 1) * width + column] >= best[row * width + column + 1] {
                row += 1
            } else {
                column += 1
            }
        }
        return prefix + middle + suffix
    }

    /// The elements on `live` keys whose text differs between the reads, named as change summaries name them.
    public func liveChanges(_ before: AccessibilitySnapshot, _ after: AccessibilitySnapshot, live: Set<String>) -> [String] {
        guard !live.isEmpty else { return [] }
        let changed = liveTextKeys(before, after).intersection(live)
        return entries(after).filter { changed.contains($0.liveKey) }.map(\.name)
    }

    /// The elements on type `keys` that are added, removed or changed between the reads, named as change summaries name them.
    public func keyChanges(_ before: AccessibilitySnapshot, _ after: AccessibilitySnapshot, keys: Set<String>) -> [String] {
        guard !keys.isEmpty else { return [] }
        let old = Dictionary(entries(before).filter { keys.contains($0.key) }.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        let new = entries(after).filter { keys.contains($0.key) }
        let changed = new.filter { entry in old[entry.key].map { $0.signature != entry.signature } ?? true }.map(\.name)
        let newKeys = Set(new.map(\.key))
        return changed + old.values.filter { !newKeys.contains($0.key) }.map(\.name).sorted()
    }

    /// The frames of the nodes on type `keys` or `live` keys in `snapshot`, for leaving their pixels out.
    public func frames(of keys: Set<String>, live: Set<String> = [], in snapshot: AccessibilitySnapshot) -> [AccessibilitySnapshot.Frame] {
        guard !keys.isEmpty || !live.isEmpty else { return [] }
        return entries(snapshot).filter { keys.contains($0.key) || live.contains($0.liveKey) }.compactMap(\.node.frame)
    }

    /// `tree` with the label and value of every node on a `live` key replaced by one placeholder, so a tree diff passes over its text.
    public func maskingLive(_ tree: UITree, live: Set<String>) -> UITree {
        guard !live.isEmpty else { return tree }
        func mask(_ nodes: [UINode], parentKey: String) -> [UINode] {
            var ordinals: [String: Int] = [:]
            return nodes.map { node in
                let identifier = Self.normalisedIdentifier(node.id)
                if let identifier, options.ignoredIdentifiers.contains(identifier) { return node }
                let component = "\(node.role.rawValue)#\(identifier ?? "")"
                let ordinal = ordinals[component, default: 0]
                ordinals[component] = ordinal + 1
                let key = "\(parentKey)/\(component)[\(ordinal)]"
                var masked = node
                if live.contains(key) {
                    masked.label = node.label.map { _ in Self.livePlaceholder }
                    masked.value = node.value.map { _ in Self.livePlaceholder }
                }
                masked.children = mask(node.children, parentKey: key)
                return masked
            }
        }
        var masked = tree
        masked.roots = mask(tree.roots, parentKey: "")
        return masked
    }

    static let livePlaceholder = "(live)"

    public func compare(
        _ before: AccessibilitySnapshot,
        _ after: AccessibilitySnapshot,
        ignoring volatile: Set<String> = [],
        live: Set<String> = []
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
            if let difference = describeDifference(from: previous, to: entry, live: live.contains(entry.liveKey)) {
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
        flatten(snapshot.roots, parentKey: "", parentLiveKey: "", into: &result)
        return result
    }

    /// Each node not ignored, with its live component (`role#identifier`) and live key among its siblings.
    private func liveSiblings(
        _ nodes: [AccessibilitySnapshot.Node], parentKey: String
    ) -> [(node: AccessibilitySnapshot.Node, identifier: String?, component: String, key: String)] {
        var ordinals: [String: Int] = [:]
        return nodes.compactMap { node in
            let identifier = Self.normalisedIdentifier(node.identifier)
            if let identifier, options.ignoredIdentifiers.contains(identifier) { return nil }
            let component = "\(node.uiRole ?? node.type)#\(identifier ?? "")"
            let ordinal = ordinals[component, default: 0]
            ordinals[component] = ordinal + 1
            return (node, identifier, component, "\(parentKey)/\(component)[\(ordinal)]")
        }
    }

    private func flatten(_ nodes: [AccessibilitySnapshot.Node], parentKey: String, parentLiveKey: String, into result: inout [Entry]) {
        var ordinals: [String: Int] = [:]
        for (node, identifier, _, liveKey) in liveSiblings(nodes, parentKey: parentLiveKey) {
            let component = "\(node.type)#\(identifier ?? "")"
            let ordinal = ordinals[component, default: 0]
            ordinals[component] = ordinal + 1
            let key = "\(parentKey)/\(component)[\(ordinal)]"
            result.append(Entry(
                key: key,
                liveKey: liveKey,
                name: Self.displayName(node, identifier: identifier),
                element: identifier.map { "\(node.type)#\($0)" } ?? Self.displayName(node, identifier: nil),
                node: node,
                signature: signature(node)
            ))
            flatten(node.children, parentKey: key, parentLiveKey: liveKey, into: &result)
        }
    }

    private func signature(_ node: AccessibilitySnapshot.Node) -> Signature {
        let precision = options.framePrecision > 0 ? options.framePrecision : 1
        let frame = node.frame.map { frame in
            [frame.x, frame.y, frame.width, frame.height].map { ($0 / precision).rounded() }
        }
        let text = !options.ignoreText
        return Signature(
            role: node.role,
            subrole: node.subrole,
            label: text ? node.label : nil,
            value: text ? node.value : nil,
            title: text ? node.title : nil,
            enabled: node.enabled,
            state: node.state,
            frame: options.ignoreFrames ? nil : frame
        )
    }

    private func describeDifference(from before: Entry, to after: Entry, live: Bool) -> String? {
        // Ignoring text also ignores a resize that came with it, as a right-aligned number's frame follows its digits.
        let textMoved = options.ignoreText
            && (before.node.label != after.node.label || before.node.value != after.node.value || before.node.title != after.node.title)
        let a = live || textMoved ? before.signature.structural : before.signature
        let b = live || textMoved ? after.signature.structural : after.signature
        let name = after.name
        if a.value != b.value, before.node.isSecure || after.node.isSecure { return "value of \(name) changed (secure field)" }
        if a.value != b.value { return "value of \(name) changed from \(Self.quoted(a.value)) to \(Self.quoted(b.value))" }
        if a.label != b.label { return "label of \(name) changed from \(Self.quoted(a.label)) to \(Self.quoted(b.label))" }
        if a.title != b.title { return "title of \(name) changed from \(Self.quoted(a.title)) to \(Self.quoted(b.title))" }
        if a.enabled != b.enabled { return "\(name) became \(b.enabled == true ? "enabled" : "disabled")" }
        if a.state.checked != b.state.checked { return "checked state of \(name) changed" }
        if a.state.selected != b.state.selected { return "selected state of \(name) changed" }
        if a.state.focused != b.state.focused { return "focused state of \(name) changed" }
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
