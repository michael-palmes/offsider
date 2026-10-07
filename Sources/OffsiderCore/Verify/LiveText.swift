import Foundation

/// Text that changes with no input in between, such as a price ticker, learnt so a verified command does not take it for its effect.
public enum LiveText {
    /// The cached tree is too old to compare with beyond this.
    public static let maximumCacheAge: TimeInterval = 30
    /// The cached tree must have been read this long after its last input, so a transition that input started is over.
    public static let quietAfterInput: TimeInterval = 2
    /// The share of structural keys the cached tree and the fresh read must have in common, so both show the same screen.
    public static let minimumSharedKeys = 0.8

    /// Live keys from the cached tree and the first read before this input; none when the cache is old, unsettled, followed by input or another screen.
    public static func learn(
        cached record: TreeCacheRecord?,
        first: UITree,
        readAt: Date,
        detector: ChangeDetector = ChangeDetector()
    ) -> Set<String> {
        guard let record, record.platform == first.platform, let cachedTree = record.tree,
              isUsable(record, readAt: readAt) else {
            return []
        }
        let old = AccessibilitySnapshot(tree: withoutLogBoxToasts(cachedTree).tree)
        let new = AccessibilitySnapshot(tree: withoutLogBoxToasts(first).tree)
        guard old.isKnown, new.isKnown, detector.sharedKeyFraction(old, new) >= minimumSharedKeys else {
            return []
        }
        return detector.liveTextKeys(old, new)
    }

    /// Read within the last 30 s, at least 2 s after its last input, with no input since.
    static func isUsable(_ record: TreeCacheRecord, readAt: Date) -> Bool {
        guard let cachedAt = record.treeReadAt, record.treeRole != .preAction else { return false }
        let age = readAt.timeIntervalSince(cachedAt)
        guard age >= 0, age <= maximumCacheAge else { return false }
        guard let input = record.lastInputAt else { return true }
        return cachedAt.timeIntervalSince(input) >= quietAfterInput
    }

    /// The tree with every React Native LogBox toast taken out, and the toasts' frames: a toast's count ticks as logs arrive, whatever the input did.
    public static func withoutLogBoxToasts(_ tree: UITree) -> (tree: UITree, toasts: [UIFrame]) {
        guard let viewport = tree.viewport else { return (tree, []) }
        var frames: [UIFrame] = []
        func strip(_ nodes: [UINode]) -> [UINode] {
            nodes.compactMap { node in
                if let toast = KnownOverlays.logBoxToast(node, viewport: viewport) {
                    frames.append(toast.frame)
                    return nil
                }
                var kept = node
                kept.children = strip(node.children)
                return kept
            }
        }
        let roots = strip(tree.roots)
        guard !frames.isEmpty else { return (tree, []) }
        var stripped = tree
        stripped.roots = roots
        return (stripped, frames)
    }

    /// True when the LogBox inspector covers the app in `after` and did not in `before`.
    public static func logBoxOpened(before: UITree, after: UITree) -> Bool {
        KnownOverlays.logBoxInspector(in: after.roots, viewport: after.viewport) != nil
            && KnownOverlays.logBoxInspector(in: before.roots, viewport: before.viewport) == nil
    }
}
