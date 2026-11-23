import Foundation
import Testing

@Suite("Screen reader", .serialized, .enabled(if: isE2EEnabled))
struct ScreenReaderE2ETests {
    static var udid: String { defaultSimulatorUDID ?? "" }

    static func run(_ command: String) async throws -> SeparatedCommandOutput {
        try await TestHelpers.runOffsiderCommandSeparated(command, simulatorUDID: udid)
    }

    static func turnOff() async {
        _ = try? await run("screen-reader off")
    }

    static func status(_ expected: String) async throws -> String {
        try await TestHelpers.waitForLabel(containing: "VoiceOver:", timeout: 10, simulatorUDID: udid) { $0 == expected }
    }

    @Test("on tells the app VoiceOver runs, a tap still counts once and a swipe is not refused, and off puts it back")
    func onAndOff() async throws {
        try await DeviceStateE2ETests.restoring(Self.turnOff) {
            _ = try await Self.run("screen-reader off")
            try await TestHelpers.launchPlaygroundApp(to: "reader-test", simulatorUDID: Self.udid)
            #expect(try await Self.status("VoiceOver: off") == "VoiceOver: off")

            let on = try await Self.run("screen-reader on --json")
            #expect(on.exitCode == 0, "\(on.stderr)")
            #expect(on.stdout.contains(#""screenReader":"on","previous":"off","service":"VoiceOver","resetBySessionStop":true"#))
            #expect(on.stderr.contains("session stop --device \(Self.udid)"))
            #expect(try await Self.status("VoiceOver: on") == "VoiceOver: on")
            #expect((try await Self.run("describe-ui")).stdout.contains("reader-test-only-row"))

            #expect((try await Self.run("tap --id reader-test-count-up")).exitCode == 0)
            #expect(try await TestHelpers.waitForLabel(containing: "Count:", timeout: 10, simulatorUDID: Self.udid) { $0 != "Count: 0" } == "Count: 1")
            #expect((try await Self.run("swipe --start-x 200 --start-y 500 --end-x 200 --end-y 400")).exitCode == 0)

            #expect((try await Self.run("screen-reader --json")).stdout.contains(#""action":"show","#))
            #expect((try await Self.run("doctor --json")).stdout.contains(#""device.screen-reader""#))

            let off = try await Self.run("screen-reader off --json")
            #expect(off.stdout.contains(#""screenReader":"off","previous":"on""#))
            #expect(try await Self.status("VoiceOver: off") == "VoiceOver: off")
            #expect(!(try await Self.run("doctor --json")).stdout.contains(#""device.screen-reader""#))
        }
    }

    @Test("a reader left on is turned off by session stop")
    func sessionStopTurnsItOff() async throws {
        try await DeviceStateE2ETests.restoring(Self.turnOff) {
            try await TestHelpers.launchPlaygroundApp(to: "reader-test", simulatorUDID: Self.udid)
            #expect((try await Self.run("screen-reader on")).exitCode == 0)
            #expect(try await Self.status("VoiceOver: on") == "VoiceOver: on")

            let stop = try await Self.run("session stop --json")
            #expect(stop.exitCode == 0, "\(stop.stderr)")
            #expect(stop.stdout.contains(#""screenReader":true"#))
            #expect(try await Self.status("VoiceOver: off") == "VoiceOver: off")
            #expect((try await Self.run("screen-reader --json")).stdout.contains(#""screenReader":"off""#))
        }
    }
}
