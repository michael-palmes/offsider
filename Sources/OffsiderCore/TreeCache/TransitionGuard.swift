import Foundation

public enum TransitionDecision: Equatable, Sendable {
    public enum Reason: String, Sendable {
        /// The last input was 500 ms or more ago, or there was none.
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
    public static let frameTolerance = 1.0

    /// A clock that stepped back counts as no time passed, so it waits the full window rather than none.
    public static func decide(target: UINode, record: TreeCacheRecord?, now: Date) -> TransitionDecision {
        guard let record else {
            return .recheck(after: noRecordGap)
        }
        guard let lastInput = record.lastInputAt else {
            return .actNow(.noRecentInput)
        }
        let elapsed = max(0, now.timeIntervalSince(lastInput))
        let windowSeconds = seconds(window)
        if elapsed >= windowSeconds {
            return .actNow(.noRecentInput)
        }
        if let roots = record.roots, hasSameFrame(target, in: roots) {
            return .actNow(.sameFrame)
        }
        return .recheck(after: .milliseconds(Int(((windowSeconds - elapsed) * 1000).rounded())))
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
