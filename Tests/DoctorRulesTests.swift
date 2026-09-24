import Foundation
import Testing
import OffsiderCore

@Suite("Doctor Rules Tests")
struct DoctorRulesTests {
    private let udid = "TEST-SIMULATOR-UDID"

    private func flagState(_ flag: Int?, running: Bool, transport: String?) -> DoctorRules.Verdict {
        DoctorRules.dtuhidState(flag: flag, dtuhiddRunning: running, dtuhidEra: true, selectedTransport: transport, udid: udid)
    }

    @Test("dtuhidd flag and process agree in the healthy states")
    func dtuhidHealthyStates() {
        #expect(flagState(0, running: false, transport: "indigo").status == .pass)
        #expect(flagState(1, running: true, transport: "dtuhid").status == .pass)
        #expect(flagState(1, running: true, transport: nil).status == .pass)
    }

    @Test("An idle dtuhidd is healthy when Offsider selected DTUHID")
    func idleDaemonWithDTUHIDPasses() {
        let verdict = flagState(1, running: false, transport: "dtuhid")
        #expect(verdict.status == .pass)
        #expect(verdict.hint == nil)
    }

    @Test("Flag set with Indigo selected fails because keyboard and button input is dropped")
    func legacyServicesOffWithIndigoFails() throws {
        let verdict = flagState(1, running: false, transport: "indigo")
        #expect(verdict.status == .fail)
        #expect(verdict.detail.contains("type, key and button"))
        let hint = try #require(verdict.hint)
        #expect(hint.contains("simctl shutdown \(udid)"))
        #expect(hint.contains("--fix"))
    }

    @Test("Flag set without dtuhidd and an unknown transport warns with the reboot hint")
    func unknownTransportWarns() {
        let verdict = flagState(1, running: false, transport: nil)
        #expect(verdict.status == .warn)
        #expect(verdict.hint?.contains("simctl shutdown \(udid)") == true)
    }

    @Test("dtuhidd running before the flag is set warns, and an unreadable flag warns")
    func dtuhidTransitionalStates() {
        #expect(flagState(0, running: true, transport: "dtuhid").status == .warn)
        #expect(flagState(nil, running: true, transport: "dtuhid").status == .warn)
        #expect(flagState(nil, running: false, transport: nil).status == .warn)
    }

    @Test("notifyutil output parses to the flag value")
    func notifyFlagParsing() {
        #expect(DoctorRules.parseNotifyFlag("com.apple.coredevice.dtuhidd.active 1\n") == 1)
        #expect(DoctorRules.parseNotifyFlag("com.apple.coredevice.dtuhidd.active 0") == 0)
        #expect(DoctorRules.parseNotifyFlag("") == nil)
        #expect(DoctorRules.parseNotifyFlag("notifyutil: error") == nil)
        #expect(DoctorRules.parseNotifyFlag("Unable to spawn notifyutil at all") == nil)
    }

    @Test("Resize Mode passes on error 24004, fails when a session answers, warns otherwise")
    func resizeMode() {
        #expect(DoctorRules.resizeMode(exitStatus: 1, output: "ERROR: ... (com.apple.dt.CoreDeviceError error 24004.)", udid: udid).status == .pass)
        let hosting = DoctorRules.resizeMode(exitStatus: 0, output: "appResize: enabled", udid: udid)
        #expect(hosting.status == .fail)
        #expect(hosting.hint?.contains("Resize Mode") == true)
        #expect(DoctorRules.resizeMode(exitStatus: 1, output: "some other failure", udid: udid).status == .warn)
        #expect(DoctorRules.resizeMode(exitStatus: -1, output: "timed out", udid: udid).status == .warn)
    }

    @Test("Stabilisation passes on the default and warns on values input will not use as given")
    func stabilization() {
        let unset = DoctorRules.stabilization(environmentValue: nil)
        #expect(unset.status == .pass)
        #expect(unset.detail.contains("25 ms"))
        #expect(DoctorRules.stabilization(environmentValue: "40").status == .pass)
        #expect(DoctorRules.stabilization(environmentValue: "0").status == .warn)
        let clamped = DoctorRules.stabilization(environmentValue: "5000")
        #expect(clamped.status == .warn)
        #expect(clamped.detail.contains("1000 ms"))
        let ignored = DoctorRules.stabilization(environmentValue: "abc")
        #expect(ignored.status == .warn)
        #expect(ignored.detail.contains("25 ms"))
    }

    @Test("Xcode below 26 fails and 27 passes")
    func xcodeVersion() {
        #expect(DoctorRules.xcodeVersion("25.4").status == .fail)
        #expect(DoctorRules.xcodeVersion(nil).status == .fail)
        #expect(DoctorRules.xcodeVersion("26.0").status == .pass)
        #expect(DoctorRules.xcodeVersion("27.0", build: "27A5218g").detail == "Xcode 27.0 (27A5218g)")
    }

    @Test("An old CoreSimulator with Xcode 27 warns")
    func coreSimulator() {
        #expect(DoctorRules.coreSimulator(version: "1155.3", xcodeMajor: 27).status == .warn)
        #expect(DoctorRules.coreSimulator(version: "1155.4", xcodeMajor: 27).status == .pass)
        #expect(DoctorRules.coreSimulator(version: "1160.1.2", xcodeMajor: 27).status == .pass)
        #expect(DoctorRules.coreSimulator(version: "1051.9", xcodeMajor: 26).status == .pass)
    }

    @Test("The DTUHID era starts at CoreSimulator 1155.4")
    func dtuhidEra() {
        #expect(DoctorRules.isDTUHIDEra(coreSimulatorVersion: "1155.4"))
        #expect(DoctorRules.isDTUHIDEra(coreSimulatorVersion: "1200"))
        #expect(!DoctorRules.isDTUHIDEra(coreSimulatorVersion: "1155.3.9"))
        #expect(!DoctorRules.isDTUHIDEra(coreSimulatorVersion: nil))
    }

    @Test("Broker directory verdicts and when --fix may remove it")
    func brokerDirectory() {
        let path = "/tmp/offsider-hid-501"
        #expect(DoctorRules.brokerDirectory(.absent, path: path).status == .pass)
        #expect(DoctorRules.brokerDirectory(.healthy(live: 2, stale: 0, unexpectedEntries: []), path: path).detail == "2 live brokers")

        let stale = BrokerDirectoryState.healthy(live: 0, stale: 1, unexpectedEntries: [])
        #expect(DoctorRules.brokerDirectory(stale, path: path).status == .warn)
        #expect(DoctorRules.brokerDirectory(stale, path: path).hint?.contains("rm -rf \"\(path)\"") == true)
        #expect(DoctorRules.isBrokerDirectoryFixable(stale))

        let staleBesideLive = BrokerDirectoryState.healthy(live: 1, stale: 1, unexpectedEntries: [])
        #expect(DoctorRules.brokerDirectory(staleBesideLive, path: path).status == .warn)
        #expect(!DoctorRules.isBrokerDirectoryFixable(staleBesideLive))

        let unexpected = BrokerDirectoryState.healthy(live: 0, stale: 0, unexpectedEntries: ["notes.txt"])
        #expect(DoctorRules.brokerDirectory(unexpected, path: path).status == .warn)
        #expect(!DoctorRules.isBrokerDirectoryFixable(unexpected))

        let ownedUnsafe = BrokerDirectoryState.unsafe(reason: "group or other can access it", ownedByCurrentUser: true)
        #expect(DoctorRules.brokerDirectory(ownedUnsafe, path: path).status == .fail)
        #expect(DoctorRules.isBrokerDirectoryFixable(ownedUnsafe))
        #expect(!DoctorRules.isBrokerDirectoryFixable(.unsafe(reason: "owned by uid 0", ownedByCurrentUser: false)))
        #expect(!DoctorRules.isBrokerDirectoryFixable(.absent))

        let file = BrokerDirectoryState.unsafe(reason: BrokerDirectoryState.notADirectoryReason, ownedByCurrentUser: true)
        #expect(DoctorRules.brokerDirectory(file, path: path).status == .fail)
        #expect(!DoctorRules.isBrokerDirectoryFixable(file))
        #expect(DoctorRules.brokerDirectory(file, path: path).hint?.contains("--fix") == false)
    }

    @Test("A boot under 10 s old warns and skips HID probes")
    func bootUptime() {
        #expect(DoctorRules.bootUptime(seconds: 4).status == .warn)
        #expect(DoctorRules.bootUptime(seconds: 4).detail.contains("4 s"))
        #expect(DoctorRules.bootUptime(seconds: 180).status == .pass)
        #expect(DoctorRules.bootUptime(seconds: 180).detail == "up 3 min")
    }

    @Test("Host checks only apply from Xcode 27")
    func deviceHubEra() {
        #expect(DoctorRules.simulatorApp(isRunning: true, xcodeMajor: 26).status == .skip)
        #expect(DoctorRules.simulatorApp(isRunning: true, xcodeMajor: 27).status == .fail)
        #expect(DoctorRules.deviceHub(.notRunning, appPath: "/X/DeviceHub.app", xcodeMajor: 26).status == .skip)
        #expect(DoctorRules.deviceHub(.missing, appPath: "/X/DeviceHub.app", xcodeMajor: 27).status == .fail)
        let notRunning = DoctorRules.deviceHub(.notRunning, appPath: "/X/DeviceHub.app", xcodeMajor: 27)
        #expect(notRunning.status == .warn)
        #expect(notRunning.hint?.contains("open -g \"/X/DeviceHub.app\"") == true)
        #expect(DoctorRules.isDeviceHubFixable(.notRunning, xcodeMajor: 27))
        #expect(!DoctorRules.isDeviceHubFixable(.runningFromOtherXcode(path: "/Y"), xcodeMajor: 27))
    }

    @Test("Missing Screen Recording permission skips the window check instead of warning")
    func deviceWindow() {
        #expect(DoctorRules.deviceWindow(.titlesUnavailable, udid: udid).status == .skip)
        #expect(DoctorRules.deviceWindow(.deviceHubNotRunning, udid: udid).status == .skip)
        #expect(DoctorRules.deviceWindow(.found, udid: udid).status == .pass)
        let missing = DoctorRules.deviceWindow(.notFound, udid: udid)
        #expect(missing.status == .warn)
        #expect(missing.hint?.contains("devices://device/open?id=\(udid)") == true)
    }

    @Test("An empty accessibility tree warns and a fetch error fails")
    func accessibility() {
        #expect(DoctorRules.accessibility(.known).status == .pass)
        #expect(DoctorRules.accessibility(.emptyRoot).status == .warn)
        #expect(DoctorRules.accessibility(.failed("boom")).status == .fail)
        #expect(DoctorRules.bootedSimulators(count: 0).status == .warn)
        #expect(DoctorRules.bootedSimulators(count: 2).status == .pass)
    }

    @Test("An unanswered dtuhidd liveness probe hints at the device window and a reboot for that simulator")
    func hidTransportUnresponsiveHint() throws {
        let hint = try #require(DoctorRules.hidTransportHint(unresponsive: true, timedOut: false, udid: udid))
        #expect(hint.hasPrefix("dtuhidd did not answer."))
        #expect(hint.contains("offsider doctor --udid \(udid) --fix"))
        #expect(hint.contains("xcrun simctl shutdown \(udid) && xcrun simctl boot \(udid)"))
    }

    @Test("A HID connect timeout hints at a reboot, and other connect errors carry no hint")
    func hidTransportTimeoutHint() throws {
        let hint = try #require(DoctorRules.hidTransportHint(unresponsive: false, timedOut: true, udid: udid))
        #expect(hint.contains("timed out"))
        #expect(hint.contains("reboot the simulator"))
        #expect(DoctorRules.hidTransportHint(unresponsive: false, timedOut: false, udid: udid) == nil)
    }

    @Test("A connected HID transport passes and reports how long it took to be ready")
    func hidTransportReportsLatency() {
        let verdict = DoctorRules.hidTransport(transport: "dtuhid", latencyMilliseconds: 1040)
        #expect(verdict.status == .pass)
        #expect(verdict.detail == "dtuhid (ready in 1040 ms)")
    }
}
