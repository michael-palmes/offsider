import Foundation

/// A foldable simulator's hinge as its locationd logs it, since Xcode 27.1's devicectl no longer reads the hinge.
public enum SimulatorHingeLog {
    static let angleMarker = "Angle value set to: "
    static let poseMarker = "Sending MagicPose event"

    /// What the log says last: the angle locationd set, else the hinge state of its newest pose event.
    public enum Reading: Equatable, Sendable {
        case angle(Double)
        case state(Posture)

        public var angle: Double? {
            guard case let .angle(degrees) = self else { return nil }
            return degrees
        }

        public var posture: Posture {
            switch self {
            case let .angle(degrees): return Posture(hingeAngle: degrees)
            case let .state(posture): return posture
            }
        }
    }

    /// Angles are info lines, kept in memory for the current boot only; pose events persist, and every boot logs one closed.
    public static func arguments(udid: String) -> [String] {
        let predicate = "subsystem == \"com.apple.locationd.Motion\" AND category == \"DeviceState\" AND "
            + "(eventMessage BEGINSWITH \"\(angleMarker)\" OR eventMessage BEGINSWITH \"\(poseMarker)\")"
        return ["simctl", "spawn", udid, "log", "show", "--info", "--last", "1h", "--style", "ndjson", "--predicate", predicate]
    }

    /// The newest angle in `log show --style ndjson` output, else the newest pose event's hinge state; nil when there is neither.
    public static func reading(in ndjson: String) -> Reading? {
        let decoder = JSONDecoder()
        var angle: Double?
        var state: Posture?
        for line in ndjson.split(whereSeparator: \.isNewline) where line.contains(angleMarker) || line.contains("hingeState:") {
            guard let message = (try? decoder.decode(Entry.self, from: Data(line.utf8)))?.eventMessage else { continue }
            if message.hasPrefix(angleMarker) {
                if let degrees = Double(message.dropFirst(angleMarker.count).trimmingCharacters(in: .whitespaces)),
                   (Double(HingeControl.range.lowerBound)...Double(HingeControl.range.upperBound)).contains(degrees) {
                    angle = degrees
                }
            } else if message.hasPrefix(poseMarker), let posture = hingeState(in: message) {
                state = posture
            }
        }
        if let angle { return .angle(angle) }
        return state.map(Reading.state)
    }

    private struct Entry: Decodable {
        let eventMessage: String?
    }

    private static func hingeState(in message: String) -> Posture? {
        guard let range = message.range(of: "hingeState:") else { return nil }
        switch message[range.upperBound...].prefix(while: \.isLetter) {
        case "Closed": return .closed
        case "PartiallyOpen": return .halfOpened
        case "OpenFlat": return .open
        default: return nil
        }
    }
}
