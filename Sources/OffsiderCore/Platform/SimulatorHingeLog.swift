import Foundation

/// A foldable simulator's hinge as its locationd logs it, since Xcode 27.1's devicectl no longer reads the hinge.
public enum SimulatorHingeLog {
    static let angleMarker = "Angle value set to: "
    static let poseMarker = "Sending MagicPose event"
    static let predicate = "subsystem == \"com.apple.locationd.Motion\" AND category == \"DeviceState\" AND "
        + "(eventMessage BEGINSWITH \"\(angleMarker)\" OR eventMessage BEGINSWITH \"\(poseMarker)\")"
    /// The window when the simulator's boot time is unknown.
    static let fallbackWindow: Duration = .seconds(24 * 3600)

    /// The newest angle locationd set, and the hinge state of its newest pose event.
    public struct Reading: Equatable, Sendable {
        public var angle: Double?
        public var state: Posture?

        public init(angle: Double? = nil, state: Posture? = nil) {
            self.angle = angle
            self.state = state
        }

        /// The guest's own state where the log has one, as apps see it; else the angle's.
        public var posture: Posture? {
            state ?? angle.map(Posture.init(hingeAngle:))
        }

        /// What `newer` read wins; what it lacks stays.
        public func updated(with newer: Reading) -> Reading {
            Reading(angle: newer.angle ?? angle, state: newer.state ?? state)
        }
    }

    /// One command's view of a simulator's hinge: the reading before its last move, so reads after it need only the lines since.
    public struct History: Sendable {
        public private(set) var base: Reading?
        public private(set) var movedAt: Date?

        public init() {}

        /// Where the next read starts: the last move when a reading from before it is kept, else the boot.
        public func start(boot: Date?) -> Date? {
            guard base != nil, let movedAt else { return boot }
            return movedAt
        }

        /// The reading a read from `start(boot:)` gives: laid over the reading before the move, else kept as that base.
        public mutating func record(_ read: Reading?) -> Reading? {
            guard let base, movedAt != nil else {
                base = read
                return read
            }
            return read.map(base.updated) ?? base
        }

        public mutating func noteMove(at date: Date, from current: Reading?) {
            base = current
            movedAt = date
        }
    }

    /// The posture with the inner display showing: half-opened only when the hinge says so.
    public static func innerPosture(_ reading: Reading?) -> Posture {
        reading?.posture == .halfOpened ? .halfOpened : .open
    }

    /// `simctl` arguments for the simulator's hinge lines from `start`, its boot or a move; else over the last day.
    public static func arguments(udid: String, since start: Date?) -> [String] {
        ["simctl", "spawn", udid, "log"] + LogText.iosLogArguments(window: start.map(LogWindow.since) ?? .last(fallbackWindow), predicate: predicate)
    }

    /// The lines in order; a closed pose event drops an earlier open angle, as every boot logs one before any angle. Nil when no line is usable.
    public static func reading(in ndjson: String) -> Reading? {
        var reading = Reading()
        for line in ndjson.split(whereSeparator: \.isNewline) where line.contains(angleMarker) || line.contains("hingeState:") {
            guard let message = LogText.parseIOSNDJSON(String(line))?.message else { continue }
            if message.hasPrefix(angleMarker), let degrees = angle(in: message) {
                reading.angle = degrees
            } else if message.hasPrefix(poseMarker), let state = hingeState(in: message) {
                reading.state = state
                if state == .closed, let angle = reading.angle, Posture(hingeAngle: angle) != .closed {
                    reading.angle = nil
                }
            }
        }
        return reading.angle == nil && reading.state == nil ? nil : reading
    }

    private static func angle(in message: String) -> Double? {
        guard let degrees = Double(message.dropFirst(angleMarker.count).trimmingCharacters(in: .whitespaces)),
              (Double(HingeControl.range.lowerBound)...Double(HingeControl.range.upperBound)).contains(degrees) else {
            return nil
        }
        return degrees
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
