import CryptoKit
import Foundation

/// One node as the diff sees it: its identity, its text line (focus left out) and whether it sits in a keyboard.
public struct TreeDiffLine: Equatable, Sendable {
    public let key: String
    public let node: UINode
    public let text: String
    public let underKeyboard: Bool
}

public struct TreeDiffEntry: Equatable, Sendable {
    public enum Kind: String, Sendable {
        case added, changed, removed
    }

    public let kind: Kind
    public let key: String
    /// The new line for `added` and `changed`, the old one for `removed`.
    public let line: TreeDiffLine
    /// The old line of a `changed` entry.
    public let previous: TreeDiffLine?
}

/// What changed between two reads of one screen, over the lines a filter keeps.
public struct TreeDiff: Equatable, Sendable {
    public static let fallbackLineCount = 60

    public let entries: [TreeDiffEntry]
    /// Lines in the new read that have an identity.
    public let lineCount: Int
    public let truncated: Bool

    public init(entries: [TreeDiffEntry], lineCount: Int, truncated: Bool) {
        self.entries = entries
        self.lineCount = lineCount
        self.truncated = truncated
    }

    /// A truncated read is never unchanged: what it left out may have changed.
    public var isUnchanged: Bool { entries.isEmpty && !truncated }

    /// 60 or more changes, or more than half the new lines, read better as the full output.
    public var shouldFallBack: Bool {
        entries.count >= Self.fallbackLineCount || Double(entries.count) > Double(lineCount) / 2
    }

    public func count(_ kind: TreeDiffEntry.Kind) -> Int {
        entries.filter { $0.kind == kind }.count
    }

    /// Additions and changes in the new order, then removals in the old order; a truncated new read lists no removals.
    public static func diff(old: [TreeDiffLine], new: [TreeDiffLine], truncated: Bool = false) -> TreeDiff {
        let oldByKey = Dictionary(old.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        let newKeys = Set(new.map(\.key))
        var entries: [TreeDiffEntry] = []
        for line in new {
            guard let previous = oldByKey[line.key] else {
                entries.append(TreeDiffEntry(kind: .added, key: line.key, line: line, previous: nil))
                continue
            }
            if previous.text != line.text {
                entries.append(TreeDiffEntry(kind: .changed, key: line.key, line: line, previous: previous))
            }
        }
        if !truncated {
            for line in old where !newKeys.contains(line.key) {
                entries.append(TreeDiffEntry(kind: .removed, key: line.key, line: line, previous: nil))
            }
        }
        return TreeDiff(entries: entries, lineCount: new.count, truncated: truncated)
    }

    public static func diff(old: UITree, new: UITree, filter: UITreeFilter = UITreeFilter()) -> TreeDiff {
        diff(old: lines(in: old, filter: filter), new: lines(in: new, filter: filter), truncated: new.sourceTruncated)
    }

    /// The nodes `filter` keeps that have an identity, in document order.
    public static func lines(in tree: UITree, filter: UITreeFilter = UITreeFilter()) -> [TreeDiffLine] {
        let rect = tree.visibleRect
        var kept: [(node: UINode, underKeyboard: Bool)] = []
        func visit(_ node: UINode, underKeyboard: Bool) {
            let underKeyboard = underKeyboard || node.role == .keyboard
            if filter.matches(node, visibleRect: rect) {
                var leaf = node
                leaf.children = []
                kept.append((leaf, underKeyboard))
            }
            for child in node.children {
                visit(child, underKeyboard: underKeyboard)
            }
        }
        for root in tree.roots {
            visit(root, underKeyboard: false)
        }
        let keys = NodeIdentity.keys(kept.map(\.node))
        return zip(kept, keys).compactMap { item, key in
            key.map { TreeDiffLine(key: $0, node: item.node, text: text(item.node), underKeyboard: item.underKeyboard) }
        }
    }

    /// The `describe-ui --format text` line with every neutral field except focus.
    public static func text(_ node: UINode) -> String {
        var node = node
        node.state.focused = nil
        return UITreeRenderer.line(node, lineFields)
    }

    /// First 16 hex of SHA-256 over every node's depth and line, focus ignored, so equal screens hash alike.
    public static func hash(_ tree: UITree) -> String {
        var canonical = ""
        func visit(_ node: UINode, depth: Int) {
            canonical += "\(depth) \(text(node))\n"
            for child in node.children {
                visit(child, depth: depth + 1)
            }
        }
        for root in tree.roots {
            visit(root, depth: 0)
        }
        return SHA256.hash(data: Data(canonical.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    private static let lineFields = Set(UIField.allCases).subtracting([.native])
}
