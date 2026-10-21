import Foundation

extension AndroidInputStep {
    /// A finger resting on a real touch screen keeps reporting where it is; gesture handlers that act only on moves wait for those reports.
    static let restingMoveMilliseconds = 50

    /// Each pause while fingers are down (`resting` from earlier steps, or put down in `steps`), with a move to where they rest every `restingMoveMilliseconds`.
    static func withRestingMoves(_ steps: [AndroidInputStep], resting: [AndroidPoint] = []) -> [AndroidInputStep] {
        var fingers = resting
        var sent: [AndroidInputStep] = []
        for step in steps {
            switch step {
            case .touch(let phase, let point):
                fingers = phase == .up ? [] : [point]
            case .touches(let phase, let points):
                fingers = phase == .up ? [] : points
            case .pause(let seconds) where !fingers.isEmpty:
                let total = milliseconds(seconds)
                guard total > restingMoveMilliseconds else { break }
                var elapsed = 0
                while elapsed + restingMoveMilliseconds < total {
                    sent.append(.pause(Double(restingMoveMilliseconds) / 1000))
                    sent.append(fingers.count == 1 ? .touch(.move, fingers[0]) : .touches(.move, fingers))
                    elapsed += restingMoveMilliseconds
                }
                sent.append(.pause(Double(total - elapsed) / 1000))
                continue
            default:
                break
            }
            sent.append(step)
        }
        return sent
    }

    /// Whether a finger rests longer than `restingMoveMilliseconds` anywhere in `steps`, so `withRestingMoves` would add a move.
    static func restsAFinger(_ steps: [AndroidInputStep], resting: [AndroidPoint] = []) -> Bool {
        var down = !resting.isEmpty
        for step in steps {
            switch step {
            case .touch(let phase, _), .touches(let phase, _): down = phase != .up
            case .pause(let seconds) where down && milliseconds(seconds) > restingMoveMilliseconds: return true
            default: break
            }
        }
        return false
    }

    /// A move to where the fingers already rest: a resting finger's report.
    func restsAt(_ fingers: [AndroidPoint]) -> Bool {
        switch self {
        case .touch(.move, let point): return fingers == [point]
        case .touches(.move, let points): return !fingers.isEmpty && fingers == points
        default: return false
        }
    }

    static func milliseconds(_ seconds: TimeInterval) -> Int {
        max(0, Int((seconds * 1000).rounded()))
    }
}
