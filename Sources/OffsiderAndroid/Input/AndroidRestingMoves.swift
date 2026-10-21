import Foundation

extension AndroidInputStep {
    /// A finger resting on a real touch screen keeps reporting where it is; gesture handlers that act only on moves wait for those reports.
    static let restingMoveMilliseconds = 50

    /// Each pause while fingers are down, with a move to where they rest at every `restingMoveMilliseconds` inside it.
    /// `resting` holds the fingers already down when the steps start.
    static func withRestingMoves(_ steps: [AndroidInputStep], resting: [AndroidPoint] = []) -> [AndroidInputStep] {
        var fingers = resting
        var sent: [AndroidInputStep] = []
        for step in steps {
            switch step {
            case .touch(let phase, let point):
                fingers = phase == .up ? [] : [point]
            case .touches(let phase, let points):
                fingers = phase == .up ? [] : points
            case .pause(let seconds) where !fingers.isEmpty && Int((seconds * 1000).rounded()) > restingMoveMilliseconds:
                let total = Int((seconds * 1000).rounded())
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
}
