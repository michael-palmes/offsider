import Foundation
import Testing

@Suite("Android screen reader", .serialized, .enabled(if: isAndroidE2EEnabled))
struct AndroidScreenReaderE2ETests {
    static let talkBack = "com.google.android.marvin.talkback"

    static func json(_ output: String) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
    }

    static func setting(_ key: String) async throws -> String {
        try await AndroidE2E.shell("settings get secure \(key)").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func notificationsGranted() async throws -> Bool {
        try await AndroidE2E.shell("dumpsys package \(talkBack) | grep -m 1 -F 'android.permission.POST_NOTIFICATIONS: granted='").contains("granted=true")
    }

    static func turnOff() async {
        _ = try? await AndroidE2E.offsider("screen-reader off")
        _ = try? await AndroidE2E.offsider("session stop")
    }

    static func presses(of what: String) async throws -> Int {
        try await AndroidE2E.shell("logcat -d").components(separatedBy: "pressed \(what)").count - 1
    }

    static func top(of id: String) async throws -> Double {
        let node = try await AndroidE2E.waitForNode { $0["id"] as? String == id }
        return try #require((node["frame"] as? [String: Any])?["y"] as? Double)
    }

    @Test("on starts TalkBack for a running app, a tap still activates once and a swipe still scrolls, and off puts everything back")
    func onAndOff() async throws {
        try await AndroidDeviceStateE2ETests.restoring(Self.turnOff) {
            try await AndroidE2E.open("gap-tabs-test", waitingFor: "gap-tabs-test-screen")
            try await AndroidE2E.run("tap --id gap-tabs-flags")
            _ = try await AndroidE2E.waitForLabel(of: "gap-tabs-flags") { $0 == "Flags: Reader Off" }
            let servicesBefore = try await Self.setting("enabled_accessibility_services")
            let grantedBefore = try await Self.notificationsGranted()

            let on = try Self.json(try await AndroidE2E.run("screen-reader on --json").stdout)
            #expect(on["screenReader"] as? String == "on" && on["previous"] as? String == "off")
            #expect(on["service"] as? String == "TalkBack" && on["platform"] as? String == "android")
            #expect(on["resetBySessionStop"] as? Bool == true)
            _ = try await AndroidE2E.waitForLabel(of: "gap-tabs-flags") { $0 == "Flags: Reader On" }
            #expect(try await Self.setting("touch_exploration_enabled") == "1")
            #expect(try Self.json(try await AndroidE2E.run("screen-reader --json").stdout)["resetBySessionStop"] as? Bool == true)

            try await AndroidE2E.shell("logcat -c")
            try await AndroidE2E.run("tap --id gap-tabs-home-row-3")
            _ = try await AndroidE2E.waitForLabel(of: "gap-tabs-pressed") { $0 == "Gap Pressed: Home Item 3" }
            #expect(try await Self.presses(of: "Home Item 3") == 1)
            let before = try await Self.top(of: "gap-tabs-home-row-12")
            try await AndroidE2E.run("swipe --start-x 200 --start-y 700 --end-x 200 --end-y 300")
            _ = try await AndroidE2E.offsider("wait --settled --timeout 5")
            #expect(try await Self.top(of: "gap-tabs-home-row-12") < before, "the list scrolled: the swipe reached the app, not TalkBack")
            try await AndroidE2E.run("tap --id gap-tabs-tab-saved")
            _ = try await AndroidE2E.waitForNode { $0["id"] as? String == "gap-tabs-saved-row-1" }
            let doctor = try await AndroidE2E.offsider("doctor --json")
            #expect(doctor.stdout.contains("device.screen-reader"))

            let off = try Self.json(try await AndroidE2E.run("screen-reader off --json").stdout)
            #expect(off["screenReader"] as? String == "off" && off["previous"] as? String == "on")
            _ = try await AndroidE2E.waitForLabel(of: "gap-tabs-flags") { $0 == "Flags: Reader Off" }
            #expect(try await Self.setting("enabled_accessibility_services") == servicesBefore)
            #expect(try await Self.setting("touch_exploration_enabled") == "0")
            #expect(try await Self.notificationsGranted() == grantedBefore)
            try await AndroidE2E.run("tap --id gap-tabs-tab-home")
            _ = try await AndroidE2E.waitForLabel(of: "gap-tabs-pressed") { $0 == "Gap Pressed: Home Tab" }
        }
    }

    @Test("TalkBack left on is turned off by session stop, which says so; TalkBack a person turned on, it leaves")
    func sessionStop() async throws {
        try await AndroidDeviceStateE2ETests.restoring(Self.turnOff) {
            let servicesBefore = try await Self.setting("enabled_accessibility_services")
            try await AndroidE2E.run("screen-reader on")
            #expect(try await AndroidE2E.run("session status").stdout.contains("screen reader"))
            #expect(try await AndroidE2E.run("session stop --json").stdout.contains(#""screenReader":true"#))
            #expect(try await Self.setting("enabled_accessibility_services") == servicesBefore)
            #expect(try await Self.setting("touch_exploration_enabled") == "0")

            try await AndroidE2E.shell("pm grant \(Self.talkBack) android.permission.POST_NOTIFICATIONS")
            try await AndroidE2E.shell("settings put secure enabled_accessibility_services \(Self.talkBack)/\(Self.talkBack).TalkBackService")
            try await AndroidDeviceStateE2ETests.restoring({ _ = try? await AndroidE2E.shell("pm revoke \(Self.talkBack) android.permission.POST_NOTIFICATIONS") }) {
                let already = try Self.json(try await AndroidE2E.run("screen-reader on --json").stdout)
                #expect(already["previous"] as? String == "on" && already["resetBySessionStop"] as? Bool == false)
                #expect(try await AndroidE2E.run("session stop --json").stdout.contains(#""screenReader":true"#) == false)
                #expect(try await Self.setting("touch_exploration_enabled") == "1")
                #expect(try Self.json(try await AndroidE2E.run("screen-reader off --json").stdout)["screenReader"] as? String == "off")
            }
        }
    }
}
