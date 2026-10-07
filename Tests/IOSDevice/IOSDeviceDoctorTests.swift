import Foundation
import OffsiderCore
import OffsiderIOSDevice
import Testing

@Suite("iOS device doctor")
@MainActor
struct IOSDeviceDoctorTests {
    static let udid = IOSDeviceFixtures.phone
    static let wired = IOSDeviceDoctorRow(
        label: "Apple iPhone",
        osVersion: "27.2",
        transportType: "wired",
        connectionState: "connected",
        pairingState: "paired",
        developerModeStatus: "enabled",
        ddiServicesAvailable: true,
        deviceSupportFinalized: true,
        tunnelState: "connected"
    )

    static func facts(
        xcode: IOSDeviceDoctorFacts.XcodeFact = .found(developerDir: "/Xcode.app/Contents/Developer", version: "27.0", build: "27A266a"),
        listing: IOSDeviceDoctorFacts.ListingFact? = .listed(wired),
        lock: IOSDeviceDoctorFacts.LockFact? = .read(passcodeRequired: true, backlightOn: true),
        hid: IOSDeviceDoctorFacts.HIDFact? = .ready,
        team: IOSDeviceDoctorFacts.TeamFact = .environment("ABCDE12345")
    ) -> IOSDeviceDoctorFacts {
        IOSDeviceDoctorFacts(udid: udid, xcode: xcode, coreDeviceVersion: "651.13.4", listing: listing, lock: lock, hid: hid, usbmuxdSocket: true, team: team)
    }

    static func row(_ change: (inout IOSDeviceDoctorRow) -> Void) -> IOSDeviceDoctorFacts.ListingFact {
        var row = wired
        change(&row)
        return .listed(row)
    }

    static func statuses(_ checks: [DoctorCheckResult]) -> [String: CheckStatus] {
        Dictionary(uniqueKeysWithValues: checks.map { ($0.id.rawValue, $0.status) })
    }

    @Test("a wired, trusted, prepared phone passes every check in the documented order; UI Automation cannot be read")
    func healthy() {
        var facts = Self.facts()
        facts.session = .running(stream: "live", detail: "live, 2736 x 2064")
        let checks = IOSDeviceDoctorRules.checks(facts)
        #expect(checks.map(\.id.rawValue) == [
            "ios-device.xcode", "ios-device.coredevice", "ios-device.listed", "ios-device.transport", "ios-device.pairing",
            "ios-device.developer-mode", "ios-device.ddi", "ios-device.tunnel", "ios-device.lock-state",
            "ios-device.hid", "ios-device.ui-automation", "ios-device.session", "ios-device.usbmuxd", "ios-device.runner-signing",
        ])
        #expect(checks.filter { $0.id != .iosDeviceUIAutomation }.allSatisfy { $0.status == .pass })
        #expect(Self.statuses(checks)["ios-device.ui-automation"] == .skip)
        #expect(checks[2].detail == "Apple iPhone (\(Self.udid)), iOS 27.2")
    }

    @Test("a broker that is not running is a skip, never started; a silent one or a failed stream warns with the restart command", arguments: [
        (IOSDeviceDoctorFacts.SessionFact?.none, CheckStatus.skip),
        (.notRunning(guiSession: true), .skip),
        (.notRunning(guiSession: false), .skip),
        (.running(stream: "opening", detail: nil), .pass),
        (.running(stream: "failed", detail: "no desktop"), .warn),
        (.unanswered, .warn),
    ])
    func session(fact: IOSDeviceDoctorFacts.SessionFact?, status: CheckStatus) {
        var facts = Self.facts()
        facts.session = fact
        let check = IOSDeviceDoctorRules.checks(facts).first { $0.id == .iosDeviceSession }
        #expect(check?.status == status)
        if status == .warn {
            #expect(check?.hint?.contains("offsider session stop --device \(Self.udid)") == true)
        }
    }

    @Test("without Xcode every device check is skipped behind ios-device.xcode")
    func noXcode() {
        let checks = IOSDeviceDoctorRules.checks(Self.facts(xcode: .notFound("No Xcode"), listing: nil, lock: nil))
        #expect(checks[0].status == .fail)
        #expect(checks.filter { $0.detail == "requires ios-device.xcode" }.count == 10)
    }

    @Test("a device that is not listed fails listed and skips the rest of the chain")
    func notListed() {
        let checks = IOSDeviceDoctorRules.checks(Self.facts(listing: .notListed, lock: nil))
        let statuses = Self.statuses(checks)
        #expect(statuses["ios-device.listed"] == .fail)
        #expect(checks.filter { $0.detail == "requires ios-device.listed" }.map(\.id.rawValue) == [
            "ios-device.transport", "ios-device.pairing", "ios-device.developer-mode", "ios-device.ddi", "ios-device.tunnel", "ios-device.lock-state",
            "ios-device.hid", "ios-device.ui-automation",
        ])
    }

    @Test("Wi-Fi fails transport, the read-only checks still report, and HID and UI Automation are skipped with the cable hint")
    func wifi() {
        let checks = IOSDeviceDoctorRules.checks(Self.facts(listing: Self.row { $0.transportType = "localNetwork" }, hid: nil))
        let transport = checks.first { $0.id == .iosDeviceTransport }
        #expect(transport?.status == .fail)
        #expect(transport?.hint?.contains("USB only") == true)
        #expect(Self.statuses(checks)["ios-device.pairing"] == .pass)
        #expect(Self.statuses(checks)["ios-device.lock-state"] == .pass)
        for id in [DoctorCheckID.iosDeviceHID, .iosDeviceUIAutomation] {
            let check = checks.first { $0.id == id }
            #expect(check?.status == .skip)
            #expect(check?.hint?.contains("Connect its cable") == true)
        }
    }

    @Test("missing developer services on Wi-Fi are never fixable: --fix would mount the disk image over the network")
    func ddiNotFixableOverWiFi() async throws {
        let facts = Self.facts(listing: Self.row { $0.transportType = "localNetwork"; $0.ddiServicesAvailable = false; $0.deviceSupportFinalized = false }, hid: nil)
        let ddi = IOSDeviceDoctorRules.checks(facts).first { $0.id == .iosDeviceDDI }
        #expect(ddi?.fixable == false)
        #expect(ddi?.hint?.contains("--fix") == false)
        #expect(!IOSDeviceDoctorRules.isDDIFixable(facts))

        let devicectl = try FakeDevicectl.listing("devicectl-list-xcode26.json")
        let result = await IOSDeviceDoctorProbe(host: .fake(devicectl), xcodeTeams: { [] }).mountDDI(udid: Self.udid, facts: facts)
        #expect(result.outcome == .skipped)
        #expect(devicectl.calls.isEmpty)
    }

    @Test("an untrusted device skips developer mode, ddi, tunnel and lock state")
    func untrusted() {
        let checks = IOSDeviceDoctorRules.checks(Self.facts(listing: Self.row { $0.pairingState = "unpaired" }, lock: nil))
        #expect(Self.statuses(checks)["ios-device.pairing"] == .fail)
        #expect(checks.filter { $0.detail == "requires ios-device.pairing" }.count == 6)
    }

    @Test("missing developer services warn and are the one fixable check")
    func ddiFixable() {
        let facts = Self.facts(listing: Self.row { $0.ddiServicesAvailable = false; $0.deviceSupportFinalized = false })
        let ddi = IOSDeviceDoctorRules.checks(facts).first { $0.id == .iosDeviceDDI }
        #expect(ddi?.status == .warn)
        #expect(ddi?.fixable == true)
        #expect(ddi?.detail.contains("preparing") == true)
        #expect(IOSDeviceDoctorRules.isDDIFixable(facts))
        #expect(!IOSDeviceDoctorRules.isDDIFixable(Self.facts()))
        #expect(IOSDeviceDoctorRules.checks(Self.facts()).filter(\.fixable).isEmpty)
    }

    @Test("a dark screen with a passcode is probably locked, never asserted locked", arguments: [
        (IOSDeviceDoctorFacts.LockFact.read(passcodeRequired: true, backlightOn: false), CheckStatus.warn, "Probably locked"),
        (.read(passcodeRequired: false, backlightOn: false), .warn, "The screen is off"),
        (.read(passcodeRequired: true, backlightOn: true), .pass, "Screen on"),
        (.read(passcodeRequired: true, backlightOn: nil), .skip, "did not report"),
        (.unreadable("timed out"), .skip, "timed out"),
    ])
    func lockState(fact: IOSDeviceDoctorFacts.LockFact, status: CheckStatus, detail: String) {
        let verdict = IOSDeviceDoctorRules.lockState(fact)
        #expect(verdict.status == status)
        #expect(verdict.detail.contains(detail))
    }

    @Test("signing passes with one team, warns with none or several, and fails a malformed variable", arguments: [
        (IOSDeviceDoctorFacts.TeamFact.environment("ABCDE12345"), CheckStatus.pass),
        (.environment("abc"), .fail),
        (.xcodeTeams(["ABCDE12345"]), .pass),
        (.xcodeTeams([]), .warn),
        (.xcodeTeams(["ABCDE12345", "ZYXWV98765"]), .warn),
    ])
    func signing(team: IOSDeviceDoctorFacts.TeamFact, status: CheckStatus) {
        #expect(IOSDeviceDoctorRules.runnerSigning(team).status == status)
    }

    @Test("Xcode 26 warns that most input needs Xcode 27; older Xcode fails")
    func xcodeMajors() {
        #expect(IOSDeviceDoctorRules.xcode(.found(developerDir: "/X", version: "26.4", build: nil)).status == .warn)
        #expect(IOSDeviceDoctorRules.xcode(.found(developerDir: "/X", version: "25.1", build: nil)).status == .fail)
        #expect(IOSDeviceDoctorRules.coreDevice("500.2", listing: .notListed).status == .warn)
        #expect(IOSDeviceDoctorRules.coreDevice("651.13.4", listing: .notListed).status == .pass)
    }

    @Test("every iOS device check id fits the existing id column")
    func idsFitColumn() {
        let longest = DoctorCheckID.allCases.filter { !$0.isPerIOSDevice }.map(\.rawValue.count).max() ?? 0
        #expect(DoctorCheckID.allCases.filter(\.isPerIOSDevice).allSatisfy { $0.rawValue.count <= longest })
        #expect(DoctorCheckID.allCases.filter(\.isPerIOSDevice).count == 14)
    }

    // MARK: Probe

    static func wiredDetails() throws -> String {
        try IOSDeviceFixtures.text("devicectl-info-details.json").replacingOccurrences(of: "\"localNetwork\"", with: "\"wired\"")
    }

    @Test("over Wi-Fi the probe reads details, lock state and displays but never opens HID")
    func probeWirelessSkipsHID() async throws {
        let hid = HIDRecorder(.ready)
        let devicectl = try FakeDevicectl.listing("devicectl-list-xcode27-disconnected.json", extra: [
            "details": ProcessCaptureResult(status: 0, stdout: try IOSDeviceFixtures.text("devicectl-info-details.json"), stderr: ""),
            "lockState": ProcessCaptureResult(status: 0, stdout: try IOSDeviceFixtures.text("devicectl-info-lockstate.json"), stderr: ""),
            "displays": ProcessCaptureResult(status: 0, stdout: try IOSDeviceFixtures.text("devicectl-info-displays.json"), stderr: ""),
        ])
        let facts = await IOSDeviceDoctorProbe(host: .fake(devicectl), xcodeTeams: { [] }, hid: hid.probe).run(udid: Self.udid).facts

        #expect(devicectl.calls.map { $0.first == "list" ? "list" : $0[2] } == ["list", "details", "lockState", "displays"])
        #expect(facts.row?.transportType == "localNetwork")
        #expect(facts.hid == nil)
        #expect(hid.calls.isEmpty)
    }

    @Test("the probe asks a wired, trusted device for details, lock state, displays and HID; the team comes from the variable")
    func probeConnected() async throws {
        let hid = HIDRecorder(.refused)
        let devicectl = try FakeDevicectl.listing("devicectl-list-xcode27-disconnected.json", extra: [
            "details": ProcessCaptureResult(status: 0, stdout: try Self.wiredDetails(), stderr: ""),
            "lockState": ProcessCaptureResult(status: 0, stdout: try IOSDeviceFixtures.text("devicectl-info-lockstate.json"), stderr: ""),
            "displays": ProcessCaptureResult(status: 0, stdout: try IOSDeviceFixtures.text("devicectl-info-displays.json"), stderr: ""),
        ])
        let host = IOSDeviceHost.fake(
            devicectl, environment: ["OFFSIDER_IOS_TEAM_ID": "ABCDE12345"], existing: [IOSDeviceDoctorProbe.usbmuxdSocket], usbmux: FakeUsbmuxListing.onUSB(Self.udid)
        )
        let probe = IOSDeviceDoctorProbe(host: host, xcodeTeams: { ["SHOULDNOTREAD"] }, hid: hid.probe)
        let facts = await probe.run(udid: Self.udid).facts

        #expect(devicectl.calls.map { $0.first == "list" ? "list" : $0[2] } == ["list", "details", "lockState", "displays"])
        #expect(facts.row?.ddiServicesAvailable == true)
        #expect(facts.row?.tunnelState == "connected")
        #expect(facts.lock == .read(passcodeRequired: true, backlightOn: false))
        #expect(facts.team == .environment("ABCDE12345"))
        #expect(facts.usbmuxdSocket && facts.usbmux == .onUSB)
        #expect(facts.coreDeviceVersion == "651.13.4")
        #expect(facts.hid == .refused)
        #expect(hid.calls == ["00000000-0000-4000-8000-0000000000A1 \(Self.udid)"])
    }

    @Test("a usbmuxd that lists nothing while devicectl sees the device wired fails ios-device.usbmuxd with the replug hint")
    func probeStaleUsbmux() async throws {
        let usbmuxd = try FakeUsbmuxd(reply: { _ in .plist(["DeviceList": [Any]()]) })
        defer { usbmuxd.stop() }
        let devicectl = try FakeDevicectl.listing("devicectl-list-xcode27-disconnected.json", extra: [
            "details": ProcessCaptureResult(status: 0, stdout: try Self.wiredDetails(), stderr: ""),
        ])
        let host = IOSDeviceHost.fake(devicectl, existing: [IOSDeviceDoctorProbe.usbmuxdSocket], usbmux: UsbmuxClient(socketPath: usbmuxd.path, timeout: 1))
        let facts = await IOSDeviceDoctorProbe(host: host, xcodeTeams: { [] }, hid: HIDRecorder(.ready).probe).run(udid: Self.udid).facts

        #expect(facts.usbmux == .notOnUSB)
        #expect(usbmuxd.received.map { $0["MessageType"] as? String } == ["ListDevices"])
        let check = try #require(IOSDeviceDoctorRules.checks(facts).first { $0.id == .iosDeviceUsbmuxd })
        #expect(check.status == .fail)
        #expect(check.hint == "Unplug and replug the cable, then retry.")
    }

    @Test("ios-device.usbmuxd passes only while usbmuxd lists the device on USB, and skips the list for a device off its cable", arguments: [
        (true, IOSDeviceDoctorFacts.UsbmuxFact?.some(.onUSB), "wired", CheckStatus.pass),
        (true, .notOnUSB, "wired", .fail),
        (true, .notOnUSB, "localNetwork", .skip),
        (true, .failed("it did not answer in time"), "wired", .fail),
        (false, nil, "wired", .fail),
    ])
    func usbmuxdVerdicts(socket: Bool, usbmux: IOSDeviceDoctorFacts.UsbmuxFact?, transport: String, status: CheckStatus) {
        var facts = Self.facts(listing: Self.row { $0.transportType = transport })
        facts.usbmuxdSocket = socket
        facts.usbmux = usbmux
        #expect(IOSDeviceDoctorRules.checks(facts).first { $0.id == .iosDeviceUsbmuxd }?.status == status)
    }

    @Test("the probe never sends a device command to a device it cannot see or that does not trust the Mac")
    func probeQuiet() async throws {
        let devicectl = try FakeDevicectl.listing("devicectl-list-xcode26.json")
        let hid = HIDRecorder(.ready)
        let probe = IOSDeviceDoctorProbe(host: .fake(devicectl), xcodeTeams: { [] }, hid: hid.probe)
        let missing = await probe.run(udid: "00008140-0000000000000001").facts
        let untrusted = await probe.run(udid: IOSDeviceFixtures.iPad).facts

        #expect(devicectl.calls.allSatisfy { $0.first == "list" })
        #expect(missing.listing == .notListed)
        #expect(untrusted.row?.pairingState == "unpaired")
        #expect(untrusted.lock == nil)
        #expect(!missing.usbmuxdSocket)
        #expect(hid.calls.isEmpty)
    }

    @Test("below CoreDevice 636 the probe reports HID unsupported without opening a socket")
    func probeBelowFloor() async throws {
        let listing = try IOSDeviceFixtures.text("devicectl-list-xcode27-disconnected.json").replacingOccurrences(of: "\"651.13.4\"", with: "\"518.24\"")
        let devicectl = FakeDevicectl(replies: [
            "list": ProcessCaptureResult(status: 0, stdout: listing, stderr: ""),
            "details": ProcessCaptureResult(status: 0, stdout: try Self.wiredDetails(), stderr: ""),
        ])
        let hid = HIDRecorder(.ready)
        let facts = await IOSDeviceDoctorProbe(host: .fake(devicectl), xcodeTeams: { [] }, hid: hid.probe).run(udid: Self.udid).facts

        #expect(facts.hid == .unsupported(coreDevice: "518.24"))
        #expect(hid.calls.isEmpty)
        let check = IOSDeviceDoctorRules.checks(facts).first { $0.id == .iosDeviceHID }
        #expect(check?.status == .skip)
        #expect(check?.hint == "Install Xcode 27 for HID input on an iPhone or iPad.")
    }

    @Test("HID and UI Automation verdicts", arguments: [
        (IOSDeviceDoctorFacts.HIDFact.ready, CheckStatus.pass, CheckStatus.skip),
        (.locked, .fail, .skip),
        (.refused, .fail, .fail),
        (.socketFailed("no tunnel"), .fail, .skip),
        (.unresponsive("no answer"), .fail, .skip),
        (.unsupported(coreDevice: "518.24"), .skip, .skip),
    ])
    func hidVerdicts(fact: IOSDeviceDoctorFacts.HIDFact, hid: CheckStatus, uiAutomation: CheckStatus) {
        #expect(IOSDeviceDoctorRules.hid(fact).status == hid)
        let verdict = IOSDeviceDoctorRules.uiAutomation(fact)
        #expect(verdict.status == uiAutomation)
        #expect((verdict.detail + (verdict.hint ?? "")).contains("Settings > Developer > UI Automation"))
    }

    @Test("a device with Developer Mode off skips HID behind developer-mode")
    func hidNeedsDeveloperMode() {
        let checks = IOSDeviceDoctorRules.checks(Self.facts(listing: Self.row { $0.developerModeStatus = "disabled" }, hid: nil))
        #expect(checks.filter { $0.detail == "requires ios-device.developer-mode" }.map(\.id.rawValue) == [
            "ios-device.ddi", "ios-device.tunnel", "ios-device.hid", "ios-device.ui-automation",
        ])
    }

    @Test("--fix mounts the disk image only when the ddi check is fixable")
    func fix() async throws {
        let devicectl = try FakeDevicectl.listing("devicectl-list-xcode26.json")
        let probe = IOSDeviceDoctorProbe(host: .fake(devicectl), xcodeTeams: { [] })
        let skipped = await probe.mountDDI(udid: Self.udid, facts: Self.facts())
        #expect(skipped.outcome == .skipped)
        #expect(devicectl.calls.isEmpty)

        let applied = await probe.mountDDI(udid: Self.udid, facts: Self.facts(listing: Self.row { $0.ddiServicesAvailable = false }))
        #expect(applied.outcome == .applied)
        #expect(applied.id == .iosDeviceDDI)
        #expect(devicectl.calls == [["device", "info", "ddiServices", "--device", Self.udid, "--auto-mount-ddis", "--timeout", "60", "--json-output", "-", "-q"]])
    }

    // MARK: Renderer

    @Test("a phone report renders like the Android-only report: no simulator lines")
    func renderer() {
        let report = DoctorReport(
            offsiderVersion: "0.0.0",
            udid: nil,
            device: DoctorDevice(id: Self.udid, platform: "ios", name: "Apple iPhone", kind: "physical"),
            xcode: XcodeSummary(developerDir: "/X", version: "27.0", build: "27A266a", coreSimulator: nil),
            booted: [],
            android: nil,
            checks: IOSDeviceDoctorRules.checks(Self.facts()),
            fixes: []
        )
        let text = DoctorRenderer.render(report)
        #expect(text.hasPrefix("Offsider doctor: Xcode 27.0 (27A266a), Apple iPhone (\(Self.udid))\n"))
        #expect(!text.contains("Booted simulators"))
        #expect(!text.contains("CoreSimulator"))
        #expect(text.hasSuffix("Result: no problems found\n"))
    }
}

/// Records each HID probe as "<identifier> <udid>" and answers with one fact.
@MainActor
final class HIDRecorder {
    private(set) var calls: [String] = []
    let answer: IOSDeviceDoctorFacts.HIDFact

    init(_ answer: IOSDeviceDoctorFacts.HIDFact) {
        self.answer = answer
    }

    var probe: IOSDeviceDoctorProbe.HIDProbe {
        { identifier, _, udid in
            self.calls.append("\(identifier) \(udid)")
            return self.answer
        }
    }
}
