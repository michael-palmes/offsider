import Foundation

public enum TransitionDecision: Equatable, Sendable {
    public enum Reason: String, Sendable {
        /// The last input was 500 ms or more ago, or there was none, and the target did not come up in the last 500 ms.
        case noRecentInput
        /// The target sits within 1 pt of where the cached tree had it.
        case sameFrame
        /// Two agreeing reads already showed the target at rest.
        case alreadySettled
        /// `--no-settle`.
        case optedOut
    }

    case actNow(Reason)
    /// Wait this long, read once more and resolve again.
    case recheck(after: Duration)
}

/// Whether a selector's target may still be moving from an earlier input, judged from the cached tree.
public enum TransitionGuard {
    public static let window: Duration = .milliseconds(500)
    public static let noRecordGap: Duration = .milliseconds(150)
    /// How long a target missing from the settled read gets before one last read.
    public static let goneGap: Duration = .milliseconds(150)
    public static let frameTolerance = 1.0
    /// After the recheck, how long apart reads go while the target still moves, and for how long in all.
    public static let movingGap: Duration = .milliseconds(100)
    public static let movingLimit: Duration = .milliseconds(1500)

    /// A clock that stepped back counts as no time passed; a keyboard that came or went since the cached read voids the same frame, as the layout may not have moved yet.
    public static func decide(target: UINode, record: TreeCacheRecord?, now: Date, keyboardShowing: @autoclosure () -> Bool = false) -> TransitionDecision {
        guard let record else {
            return .recheck(after: noRecordGap)
        }
        let windowSeconds = seconds(window)
        guard let lastInput = record.lastInputAt, max(0, now.timeIntervalSince(lastInput)) < windowSeconds else {
            return appeared(target, since: record, now: now) ?? .actNow(.noRecentInput)
        }
        let elapsed = max(0, now.timeIntervalSince(lastInput))
        if let roots = record.roots, hasSameFrame(target, in: roots),
           keyboardShowing() == record.tree.map(TextFocus.hasKeyboard) {
            return .actNow(.sameFrame)
        }
        return .recheck(after: .milliseconds(Int(((windowSeconds - elapsed) * 1000).rounded())))
    }

    /// A target a whole cached read under 500 ms ago lacked came up since, in a window that may still slide in with its frames already final.
    static func appeared(_ target: UINode, since record: TreeCacheRecord, now: Date) -> TransitionDecision? {
        guard let roots = record.roots, !record.truncated, let readAt = record.treeReadAt else { return nil }
        let since = max(0, now.timeIntervalSince(readAt))
        let windowSeconds = seconds(window)
        guard since < windowSeconds, !roots.contains(where: { $0.flattened().contains { NodeIdentity.isGuardMatch($0, target) } }) else { return nil }
        return .recheck(after: .milliseconds(Int(((windowSeconds - since) * 1000).rounded())))
    }

    static func hasSameFrame(_ target: UINode, in roots: [UINode]) -> Bool {
        guard let frame = target.frame else { return false }
        return roots.contains { root in
            root.flattened().contains { node in
                guard NodeIdentity.isGuardMatch(node, target), let old = node.frame else { return false }
                return abs(old.x - frame.x) <= frameTolerance && abs(old.y - frame.y) <= frameTolerance
                    && abs(old.width - frame.width) <= frameTolerance && abs(old.height - frame.height) <= frameTolerance
            }
        }
    }

    public static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }
}
