import Foundation
import OffsiderCore
import Testing

@Suite("Simulator hinge log")
struct SimulatorHingeLogTests {
    typealias Reading = SimulatorHingeLog.Reading

    /// One `log show --style ndjson` event, trimmed to the keys the guest's log carries for these lines.
    struct Event: Encodable {
        let eventType = "logEvent"
        let messageType: String
        let subsystem = "com.apple.locationd.Motion"
        let category = "DeviceState"
        let timestamp = "2026-01-01 00:00:00.000000+0000"
        let eventMessage: String
    }

    static func entry(_ message: String, type: String = "Info") -> String {
        String(decoding: try! JSONEncoder().encode(Event(messageType: type, eventMessage: message)), as: UTF8.self)
    }

    static func angle(_ degrees: String) -> String {
        entry("Angle value set to: \(degrees)")
    }

    static func pose(_ state: String) -> String {
        entry(
            "Sending MagicPose event to client: CMMagicPoseEvent deviceOrientation:Portrait deviceOrientation0:Portrait "
                + "deviceOrientation1:Portrait hingeState:\(state) tabletopPose:Ambiguous stableOrientationState:Ambiguous timestamp: 12.5",
            type: "Default"
        )
    }

    static let summary = #"{"count":3,"finished":1}"#

    static func reading(_ lines: String...) -> Reading? {
        SimulatorHingeLog.reading(in: (lines + [summary]).joined(separator: "\n"))
    }

    @Test("the last angle of a sweep is the angle, and the newest pose event's state is the posture")
    func newestAngleAndState() {
        let reading = Self.reading(Self.angle("180.000000"), Self.pose("PartiallyOpen"), Self.angle("150.000000"), Self.angle("120.000000"), Self.pose("PartiallyOpen"))
        #expect(reading == Reading(angle: 120, state: .halfOpened))
        #expect(reading?.posture == .halfOpened)
    }

    @Test("the guest's own state names the posture where its threshold and Offsider's differ")
    func guestStateWins() {
        #expect(Self.reading(Self.angle("170.000000"), Self.pose("PartiallyOpen"))?.posture == .halfOpened)
    }

    @Test("without pose events the angle names the posture", arguments: [("120.000000", Posture.halfOpened), ("180.000000", .open), ("4.000000", .closed)])
    func angleOnly(degrees: String, posture: Posture) {
        #expect(Self.reading(Self.angle(degrees))?.posture == posture)
    }

    @Test("a fractional angle, as Device Hub's slider sends, reads as it was set")
    func fractionalAngle() {
        #expect(Self.reading(Self.angle("127.834512"))?.angle == 127.834512)
    }

    @Test("once the angles have aged out of the log, the newest pose event's state is the reading", arguments: [
        ("Closed", Posture.closed), ("PartiallyOpen", .halfOpened), ("OpenFlat", .open),
    ])
    func stateWithoutAngles(state: String, posture: Posture) {
        let reading = Self.reading(Self.pose("Closed"), Self.pose("OpenFlat"), Self.pose(state))
        #expect(reading == Reading(state: posture))
    }

    @Test("a closed pose event after an open angle, as a boot logs, leaves no angle")
    func closedPoseDropsOpenAngle() {
        #expect(Self.reading(Self.angle("120.000000"), Self.pose("Closed")) == Reading(state: .closed))
    }

    @Test("a closing sweep keeps its angle around the closed pose event")
    func closingSweepKeepsAngle() {
        #expect(Self.reading(Self.angle("30.000000"), Self.angle("6.000000"), Self.pose("Closed"), Self.angle("0.000000")) == Reading(angle: 0, state: .closed))
        #expect(Self.reading(Self.angle("6.000000"), Self.pose("Closed")) == Reading(angle: 6, state: .closed))
    }

    @Test("a log with no usable hinge line gives no reading", arguments: [
        "",
        "getpwuid_r did not find a match for uid 501\n" + summary,
        angle("nan"),
        angle("-4.000000"),
        angle("361.000000"),
        angle("1e300"),
        pose("Ambiguous"),
        "{\"eventType\":\"logEvent\",\"eventMessage\":\"Angle value set to: 90.0\"",
        entry("Processing AVP event - Source: hinge-slider-control, Type: range"),
    ])
    func noReading(output: String) {
        #expect(SimulatorHingeLog.reading(in: output) == nil)
    }

    @Test("an unusable angle line leaves the earlier angle as the reading")
    func unusableAngleKeepsEarlier() {
        #expect(Self.reading(Self.angle("90.000000"), Self.angle("nan")) == Reading(angle: 90))
    }

    @Test("a newer reading's lines win and what it lacks stays")
    func updated() {
        let before = Reading(angle: 180, state: .open)
        #expect(before.updated(with: Reading(angle: 120)) == Reading(angle: 120, state: .open))
        #expect(before.updated(with: Reading(angle: 120, state: .halfOpened)) == Reading(angle: 120, state: .halfOpened))
        #expect(before.updated(with: Reading()) == before)
    }

    @Test("after a move, reads start at it and lie over the reading from before it")
    func historyAfterMove() {
        let boot = Date(timeIntervalSince1970: 1_000)
        let moved = Date(timeIntervalSince1970: 2_000)
        var history = SimulatorHingeLog.History()
        #expect(history.start(boot: boot) == boot)
        #expect(history.record(Reading(angle: 180, state: .open)) == Reading(angle: 180, state: .open))

        history.noteMove(at: moved, from: Reading(angle: 180, state: .open))
        #expect(history.start(boot: boot) == moved)
        #expect(history.record(nil) == Reading(angle: 180, state: .open))
        #expect(history.record(Reading(angle: 150)) == Reading(angle: 150, state: .open))
        #expect(history.record(Reading(angle: 120, state: .halfOpened)) == Reading(angle: 120, state: .halfOpened))
    }

    @Test("a move with no reading before it reads from the boot again, then keeps that reading")
    func historyWithoutBase() {
        let boot = Date(timeIntervalSince1970: 1_000)
        let moved = Date(timeIntervalSince1970: 2_000)
        var history = SimulatorHingeLog.History()
        history.noteMove(at: moved, from: nil)
        #expect(history.start(boot: boot) == boot)
        #expect(history.record(Reading(angle: 120, state: .halfOpened)) == Reading(angle: 120, state: .halfOpened))
        #expect(history.start(boot: boot) == moved)
        #expect(history.record(Reading(angle: 90)) == Reading(angle: 90, state: .halfOpened))
    }

    @Test("with the inner display showing, only a half-opened hinge reads half-opened", arguments: [
        (Reading?.some(Reading(state: .halfOpened)), Posture.halfOpened),
        (Reading(angle: 120), .halfOpened),
        (Reading(angle: 180, state: .open), .open),
        (Reading(state: .closed), .open),
        (nil, .open),
    ])
    func innerPosture(reading: Reading?, posture: Posture) {
        #expect(SimulatorHingeLog.innerPosture(reading) == posture)
    }

    @Test("the read covers the simulator's boot, else the last day, and includes the info lines the angles are on")
    func readWindow() {
        let udid = "00000000-0000-0000-0000-000000000001"
        let bounded = SimulatorHingeLog.arguments(udid: udid, since: Date(timeIntervalSince1970: 1_790_000_000))
        #expect(bounded.contains(udid) && bounded.contains("--info"))
        #expect(bounded.contains("@1790000000") && !bounded.contains("--last"))
        let unbounded = SimulatorHingeLog.arguments(udid: udid, since: nil)
        #expect(unbounded.contains("86400s") && !unbounded.contains("--start"))
    }
}
