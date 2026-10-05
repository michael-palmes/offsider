import Foundation
import OffsiderCore
import OffsiderIOSDevice
import Testing

@Suite("iOS device doctor")
@MainActor
struct IOSDeviceDoctorTests {
    static let udid = IOSDeviceFixtures.phone
    static let wired = IOSDeviceDoctorRow(
        label: "Apple iPhone 15 Pro Max",
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
        team: IOSDeviceDoctorFacts.TeamFact = .environment("ABCDE12345")
    ) -> IOSDeviceDoctorFacts {
        IOSDeviceDoctorFacts(udid: udid, xcode: xcode, coreDeviceVersion: "651.13.4", listing: listing, lock: lock, usbmuxdSocket: true, team: team)
    }

    static func row(_ change: (inout IOSDeviceDoctorRow) -> Void) -> IOSDeviceDoctorFacts.ListingFact {
        var row = wired
        change(&row)
        return .listed(row)
    }

    static func statuses(_ checks: [DoctorCheckResult]) -> [String: CheckStatus] {
        Dictionary(uniqueKeysWithValues: checks.map { ($0.id.rawValue, $0.status) })
    }

    @Test("a wired, trusted, prepared phone passes every check in the documented order")
    func healthy() {
        let checks = IOSDeviceDoctorRules.checks(Self.facts())
        #expect(checks.map(\.id.rawValue) == [
            "ios-device.xcode", "ios-device.coredevice", "ios-device.listed", "ios-device.transport", "ios-device.pairing",
            "ios-device.developer-mode", "ios-device.ddi", "ios-device.tunnel", "ios-device.lock-state", "ios-device.usbmuxd", "ios-device.runner-signing",
        ])
        #expect(checks.allSatisfy { $0.status == .pass })
        #expect(checks[2].detail == "Apple iPhone 15 Pro Max (\(Self.udid)), iOS 27.2")
    }

    @Test("without Xcode every device check is skipped behind ios-device.xcode")
    func noXcode() {
        let checks = IOSDeviceDoctorRules.checks(Self.facts(xcode: .notFound("No Xcode"), listing: nil, lock: nil))
        #expect(checks[0].status == .fail)
        #expect(checks.filter { $0.detail == "requires ios-device.xcode" }.count == 8)
    }

    @Test("a device that is not listed fails listed and skips the rest of the chain")
    func notListed() {
        let checks = IOSDeviceDoctorRules.checks(Self.facts(listing: .notListed, lock: nil))
        let statuses = Self.statuses(checks)
        #expect(statuses["ios-device.listed"] == .fail)
        #expect(checks.filter { $0.detail == "requires ios-device.listed" }.map(\.id.rawValue) == [
            "ios-device.transport", "ios-device.pairing", "ios-device.developer-mode", "ios-device.ddi", "ios-device.tunnel", "ios-device.lock-state",
        ])
    }

    @Test("Wi-Fi fails transport but the other device checks still report")
    func wifi() {
        let checks = IOSDeviceDoctorRules.checks(Self.facts(listing: Self.row { $0.transportType = "localNetwork" }))
        let transport = checks.first { $0.id == .iosDeviceTransport }
        #expect(transport?.status == .fail)
        #expect(transport?.hint?.contains("USB only") == true)
        #expect(Self.statuses(checks)["ios-device.pairing"] == .pass)
    }

    @Test("an untrusted device skips developer mode, ddi, tunnel and lock state")
    func untrusted() {
        let checks = IOSDeviceDoctorRules.checks(Self.facts(listing: Self.row { $0.pairingState = "unpaired" }, lock: nil))
        #expect(Self.statuses(checks)["ios-device.pairing"] == .fail)
        #expect(checks.filter { $0.detail == "requires ios-device.pairing" }.count == 4)
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
        #expect(DoctorCheckID.allCases.filter(\.isPerIOSDevice).count == 11)
    }

    // MARK: Probe

    @Test("the probe asks a connected, trusted device for details, lock state and displays; the team comes from the variable")
    func probeConnected() async throws {
        let devicectl = try FakeDevicectl.listing("devicectl-list-xcode27-disconnected.json", extra: [
            "details": ProcessCaptureResult(status: 0, stdout: try IOSDeviceFixtures.text("devicectl-info-details.json"), stderr: ""),
            "lockState": ProcessCaptureResult(status: 0, stdout: try IOSDeviceFixtures.text("devicectl-info-lockstate.json"), stderr: ""),
            "displays": ProcessCaptureResult(status: 0, stdout: try IOSDeviceFixtures.text("devicectl-info-displays.json"), stderr: ""),
        ])
        let probe = IOSDeviceDoctorProbe(host: .fake(devicectl, environment: ["OFFSIDER_IOS_TEAM_ID": "ABCDE12345"], existing: [IOSDeviceDoctorProbe.usbmuxdSocket]), xcodeTeams: { ["SHOULDNOTREAD"] })
        let facts = await probe.run(udid: Self.udid).facts

        #expect(devicectl.calls.map { $0.first == "list" ? "list" : $0[2] } == ["list", "details", "lockState", "displays"])
        #expect(facts.row?.ddiServicesAvailable == true)
        #expect(facts.row?.tunnelState == "connected")
        #expect(facts.lock == .read(passcodeRequired: true, backlightOn: false))
        #expect(facts.team == .environment("ABCDE12345"))
        #expect(facts.usbmuxdSocket)
        #expect(facts.coreDeviceVersion == "651.13.4")
    }

    @Test("the probe never sends a device command to a device it cannot see or that does not trust the Mac")
    func probeQuiet() async throws {
        let devicectl = try FakeDevicectl.listing("devicectl-list-xcode26.json")
        let probe = IOSDeviceDoctorProbe(host: .fake(devicectl), xcodeTeams: { [] })
        let missing = await probe.run(udid: "00008140-0000000000000001").facts
        let untrusted = await probe.run(udid: IOSDeviceFixtures.iPad).facts

        #expect(devicectl.calls.allSatisfy { $0.first == "list" })
        #expect(missing.listing == .notListed)
        #expect(untrusted.row?.pairingState == "unpaired")
        #expect(untrusted.lock == nil)
        #expect(!missing.usbmuxdSocket)
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
            device: DoctorDevice(id: Self.udid, platform: "ios", name: "Apple iPhone 15 Pro Max", kind: "physical"),
            xcode: XcodeSummary(developerDir: "/X", version: "27.0", build: "27A266a", coreSimulator: nil),
            booted: [],
            android: nil,
            checks: IOSDeviceDoctorRules.checks(Self.facts()),
            fixes: []
        )
        let text = DoctorRenderer.render(report)
        #expect(text.hasPrefix("Offsider doctor: Xcode 27.0 (27A266a), Apple iPhone 15 Pro Max (\(Self.udid))\n"))
        #expect(!text.contains("Booted simulators"))
        #expect(!text.contains("CoreSimulator"))
        #expect(text.hasSuffix("Result: no problems found\n"))
    }
}
