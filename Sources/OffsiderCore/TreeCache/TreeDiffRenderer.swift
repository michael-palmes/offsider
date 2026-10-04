import Foundation

/// `describe-ui --diff`: what changed since the cached tree, `unchanged since`, or the full text view.
public enum TreeDiffRenderer {
    /// `base` is the usable cached record, if any; `options` is a text view, whose filter both trees share.
    public static func render(_ tree: UITree, base: TreeCacheRecord?, options: UITreeRenderOptions, now: Date) -> String {
        let header = UITreeRenderer.header(tree) + "\n"
        guard let base, let old = base.tree else {
            return header + "# no earlier tree for this device; full output follows\n" + fullBody(tree, options)
        }
        let since = "since \(base.command) \(max(0, Int((now.timeIntervalSince(base.writtenAt) * 1000).rounded()))) ms ago"
        let hash = TreeDiff.hash(tree)
        let diff = TreeDiff.diff(old: old, new: tree, filter: options.filter)
        if (hash == base.hash && !tree.sourceTruncated) || diff.isUnchanged {
            return header + "# unchanged \(since) (\(hash))\n"
        }
        if diff.shouldFallBack {
            return header + "# \(diff.entries.count) lines changed \(since); full output follows\n" + fullBody(tree, options)
        }
        var output = header
        output += "# changes \(since): \(diff.count(.added)) added, \(diff.count(.changed)) changed, \(diff.count(.removed)) removed\n"
        for entry in diff.entries {
            switch entry.kind {
            case .added:
                output += "added \(entry.line.text)\n"
            case .changed:
                output += "changed \(entry.line.text) (was: \(entry.previous?.text ?? ""))\n"
            case .removed:
                output += "removed \(entry.line.text)\n"
            }
        }
        return output
    }

    /// The normal text output without its header line.
    private static func fullBody(_ tree: UITree, _ options: UITreeRenderOptions) -> String {
        let text = String(decoding: UITreeRenderer.render(tree, options), as: UTF8.self)
        guard let newline = text.firstIndex(of: "\n") else { return "" }
        return String(text[text.index(after: newline)...])
    }
}
