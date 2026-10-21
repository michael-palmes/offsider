import Foundation
import OffsiderCore
import Testing

@Suite("Simulator hinge log")
struct SimulatorHingeLogTests {
    /// One `log show --style ndjson` line, trimmed to the keys the guest's log carries for these events.
    static func entry(_ message: String, type: String = "Info") -> String {
        let object: [String: Any] = [
            "timestamp": "2026-01-01 00:00:00.000000+0000",
            "messageType": type,
            "subsystem": "com.apple.locationd.Motion",
            "category": "DeviceState",
            "eventMessage": message,
        ]
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
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

    @Test("the last angle of a sweep wins, even after a later pose event from turning the device")
    func newestAngle() {
        let output = [Self.angle("180.000000"), Self.pose("PartiallyOpen"), Self.angle("150.000000"), Self.angle("120.000000"), Self.pose("PartiallyOpen"), Self.summary]
            .joined(separator: "\n")
        let reading = SimulatorHingeLog.reading(in: output)
        #expect(reading == .angle(120))
        #expect(reading?.posture == .halfOpened)
    }

    @Test("a fractional angle, as Device Hub's slider sends, reads as it was set")
    func fractionalAngle() {
        #expect(SimulatorHingeLog.reading(in: Self.angle("127.834512"))?.angle == 127.834512)
    }

    @Test("once the angles have aged out of the log, the newest pose event's hinge state is the reading", arguments: [
        ("Closed", Posture.closed), ("PartiallyOpen", .halfOpened), ("OpenFlat", .open),
    ])
    func stateWithoutAngles(state: String, posture: Posture) {
        let output = [Self.pose("Closed"), Self.pose("OpenFlat"), Self.pose(state), Self.summary].joined(separator: "\n")
        let reading = SimulatorHingeLog.reading(in: output)
        #expect(reading == .state(posture))
        #expect(reading?.angle == nil)
    }

    @Test("a log with no usable hinge line gives no reading", arguments: [
        "",
        "getpwuid_r did not find a match for uid 501\n" + summary,
        angle("nan"),
        angle("-4.000000"),
        angle("361.000000"),
        angle("1e300"),
        pose("Ambiguous"),
        "{\"eventMessage\":\"Angle value set to: 90.0\"",
        entry("Processing AVP event - Source: hinge-slider-control, Type: range"),
    ])
    func noReading(output: String) {
        #expect(SimulatorHingeLog.reading(in: output) == nil)
    }

    @Test("an unusable angle line leaves the earlier angle as the reading")
    func unusableAngleKeepsEarlier() {
        #expect(SimulatorHingeLog.reading(in: [Self.angle("90.000000"), Self.angle("nan")].joined(separator: "\n")) == .angle(90))
    }

    @Test("the read asks the named simulator's log for info lines, where the angles are")
    func readsInfoLines() {
        let arguments = SimulatorHingeLog.arguments(udid: "00000000-0000-0000-0000-000000000001")
        #expect(Array(arguments.prefix(5)) == ["simctl", "spawn", "00000000-0000-0000-0000-000000000001", "log", "show"])
        #expect(arguments.contains("--info"))
        #expect(arguments.contains { $0.contains("Angle value set to: ") })
    }
}
