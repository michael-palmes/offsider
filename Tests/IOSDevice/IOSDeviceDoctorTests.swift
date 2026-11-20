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
        facts.runnerBuild = .built(team: "ABCDE12345", prefix: "com.mpalmes.offsider")
        facts.runnerTrust = .running
        let checks = IOSDeviceDoctorRules.checks(facts)
        #expect(checks.map(\.id.rawValue) == [
            "ios-device.xcode", "ios-device.coredevice", "ios-device.listed", "ios-device.transport", "ios-device.pairing",
            "ios-device.developer-mode", "ios-device.ddi", "ios-device.tunnel", "ios-device.lock-state",
            "ios-device.hid", "ios-device.ui-automation", "ios-device.session", "ios-device.usbmuxd", "ios-device.runner-signing",
            "ios-device.runner-build", "ios-device.runner-trust",
        ])
        #expect(checks.filter { $0.id != .iosDeviceUIAutomation }.allSatisfy { $0.status == .pass })
        #expect(Self.statuses(checks)["ios-device.ui-automation"] == .skip)
        #expect(checks[2].detail == "Apple iPhone (\(Self.udid)), iOS 27.2")
    }

    @Test("a sleeping display names caffeinate, and no desktop session names the Mac's desktop")
    func sessionDesktopHints() {
        var facts = Self.facts()
        facts.session = .notRunning(.asleep)
        let asleep = IOSDeviceDoctorRules.checks(facts).first { $0.id == .iosDeviceSession }
        #expect(asleep?.detail.contains("display is asleep") == true)
        #expect(asleep?.hint?.contains("caffeinate -d") == true)
        facts.session = .notRunning(.none)
        let none = IOSDeviceDoctorRules.checks(facts).first { $0.id == .iosDeviceSession }
        #expect(none?.detail.contains("no desktop session") == true)
        #expect(none?.hint?.contains("caffeinate") == false)
    }

    @Test("a broker that is not running is a skip, never started; a silent one or a failed stream warns with the restart command", arguments: [
        (IOSDeviceDoctorFacts.SessionFact?.none, CheckStatus.skip),
        (.notRunning(.awake), .skip),
        (.notRunning(.asleep), .skip),
        (.notRunning(.none), .skip),
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

    @Test("without Xcode every device check and the runner build are skipped behind ios-device.xcode")
    func noXcode() {
        let checks = IOSDeviceDoctorRules.checks(Self.facts(xcode: .notFound("No Xcode"), listing: nil, lock: nil))
        #expect(checks[0].status == .fail)
        #expect(checks.filter { $0.detail == "requires ios-device.xcode" }.count == 11)
        #expect(Self.statuses(checks)["ios-device.runner-build"] == .skip)
    }

    // MARK: Runner build and trust

    @Test("the runner build check reads the cache only: built passes, not built warns with the build command, and a recorded failure fails with its one fix", arguments: [
        (IOSDeviceDoctorFacts.RunnerBuildFact.built(team: "ABCDE12345", prefix: "com.mpalmes.offsider"), CheckStatus.pass, nil as String?),
        (.notBuilt(team: "ABCDE12345", prefix: "com.mpalmes.offsider", needsPerson: false), .warn, "offsider runner build --device \(IOSDeviceFixtures.phone)"),
        (.notBuilt(team: "ABCDE12345", prefix: "com.example.qa", needsPerson: true), .warn, "Ask the user to run `offsider runner build --device \(IOSDeviceFixtures.phone)` in their own terminal"),
        (.appIDTaken(appID: "com.mpalmes.offsider.runner", team: "ABCDE12345", fix: "offsider devices add --device X --test-device --team ABCDE12345 --runner-prefix dev.offsider.abcde12345"), .fail, "`offsider devices add --device X --test-device --team ABCDE12345 --runner-prefix dev.offsider.abcde12345`"),
        (.notRegistered(team: "ABCDE12345"), .fail, "offsider runner build --register-device --device \(IOSDeviceFixtures.phone)"),
        (.failed(team: "ABCDE12345", prefix: "com.mpalmes.offsider", log: "/tmp/build.log"), .warn, "offsider runner build --device"),
        (.profileExpiring(team: "ABCDE12345", prefix: "com.mpalmes.offsider", expires: Date(timeIntervalSince1970: 1_794_441_600), expired: true), .warn, "Run `offsider runner build --device \(IOSDeviceFixtures.phone)` now to renew it"),
        (.unsettled(message: "OFFSIDER_IOS_RUNNER_PREFIX is com.example.qa, but this device's allowance names runner prefix dev.offsider.abcde12345", hint: "offsider devices add"), .fail, "offsider devices add"),
    ])
    func runnerBuildVerdicts(fact: IOSDeviceDoctorFacts.RunnerBuildFact, status: CheckStatus, hint: String?) {
        var facts = Self.facts()
        facts.runnerBuild = fact
        let check = IOSDeviceDoctorRules.checks(facts).first { $0.id == .iosDeviceRunnerBuild }
        #expect(check?.status == status)
        if let hint { #expect(check?.hint?.contains(hint) == true) } else { #expect(check?.hint == nil) }
    }

    @Test("another team's App ID never reads as a registration failure in doctor")
    func appIDTakenNotRegistration() {
        var facts = Self.facts()
        facts.runnerBuild = .appIDTaken(appID: "com.mpalmes.offsider.runner", team: "ABCDE12345", fix: "offsider devices add --device X --team ABCDE12345 --runner-prefix dev.offsider.abcde12345")
        let check = IOSDeviceDoctorRules.checks(facts).first { $0.id == .iosDeviceRunnerBuild }
        #expect(check?.detail.contains("another Apple team owns its App ID com.mpalmes.offsider.runner") == true)
        #expect((check?.detail ?? "").localizedCaseInsensitiveContains("regist") == false)
    }

    @Test("an untrusted certificate fails with the Settings path and the read that clears it; a running runner passes; nothing recorded is a skip, never a pass")
    func runnerTrustVerdicts() {
        let udid = "00008130-0000000000000001"
        #expect(IOSDeviceDoctorRules.runnerTrust(.untrusted(team: "ABCDE12345"), signing: .pass, udid: udid).status == .fail)
        #expect(IOSDeviceDoctorRules.runnerTrust(.untrusted(team: "ABCDE12345"), signing: .pass, udid: udid).hint == "On the device, open Settings > General > VPN & Device Management and trust the developer certificate, then read its screen again (`offsider describe-ui --summary --device \(udid)`): the runner's next start clears this.")
        #expect(IOSDeviceDoctorRules.runnerTrust(.running, signing: .pass, udid: udid).status == .pass)
        #expect(IOSDeviceDoctorRules.runnerTrust(.unknown, signing: .pass, udid: udid).status == .skip)
        #expect(IOSDeviceDoctorRules.runnerTrust(.untrusted(team: "ABCDE12345"), signing: .warn, udid: udid).detail == "requires ios-device.runner-signing")
    }

    @Test("with no team chosen, the runner build and trust checks wait on runner-signing")
    func runnerChecksNeedTeam() {
        var facts = Self.facts(team: .xcodeTeams(["ABCDE12345"]))
        facts.runnerBuild = .notBuilt(team: "ABCDE12345", prefix: "com.mpalmes.offsider", needsPerson: false)
        let statuses = Self.statuses(IOSDeviceDoctorRules.checks(facts))
        #expect(statuses["ios-device.runner-build"] == .skip && statuses["ios-device.runner-trust"] == .skip)
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
        (.locked, .warn, "Locked"),
    ])
    func lockState(fact: IOSDeviceDoctorFacts.LockFact, status: CheckStatus, detail: String) {
        let verdict = IOSDeviceDoctorRules.lockState(fact)
        #expect(verdict.status == status)
        #expect(verdict.detail.contains(detail))
    }

    @Test("signing passes with a chosen team, warns whenever only Xcode's teams exist, and fails a malformed variable", arguments: [
        (IOSDeviceDoctorFacts.TeamFact.environment("ABCDE12345"), CheckStatus.pass),
        (.allowance("ABCDE12345"), .pass),
        (.environment("abc"), .fail),
        (.xcodeTeams(["ABCDE12345"]), .warn),
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
        #expect(DoctorCheckID.allCases.filter(\.isPerIOSDevice).count == 16)
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

    /// A host whose home holds the runner cache, with the bundled source and nothing on the device: what the runner checks read.
    struct RunnerHome {
        let home: URL
        let source: URL
        let devicectl: FakeDevicectl
        var host: IOSDeviceHost

        init(environment: [String: String] = ["OFFSIDER_IOS_TEAM_ID": "ABCDE12345"]) throws {
            home = FileManager.default.temporaryDirectory.appendingPathComponent("offsider-doctor-home-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: home.appendingPathComponent("private"), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            source = try RunnerBuilderTests.sourceDirectory()
            devicectl = try FakeDevicectl.listing("devicectl-list-xcode26.json")
            host = IOSDeviceHost.fake(devicectl, environment: environment, privateRoot: home.appendingPathComponent("private").path)
            host.homeDirectory = home
            host.runnerSource = source
        }

        /// The cache folder the builder uses for this device, team and prefix.
        func build(team: String = "ABCDE12345", prefix: String = "com.mpalmes.offsider") throws -> URL {
            let key = XcodeRunnerBuilder.key(sourceDigest: try XcodeRunnerBuilder.sourceDigest(of: source), xcodeBuild: "27A266a", team: team, prefix: prefix, destination: .device(udid: IOSDeviceFixtures.phone))
            let directory = XcodeRunnerBuilder.defaultCacheRoot(home: home).appendingPathComponent(key, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            return directory
        }

        func remove() {
            try? FileManager.default.removeItem(at: home)
            try? FileManager.default.removeItem(at: source)
        }
    }

    static func allowance(prefix: String? = nil) -> DeviceAllowance {
        DeviceAllowance(platform: .ios, key: IOSDeviceFixtures.phone, name: "Test iPhone", added: Date(timeIntervalSince1970: 1_790_000_000), expires: nil, apps: [], team: "ABCDE12345", runnerPrefix: prefix, testDevice: true)
    }

    @Test("the probe finds the cached build for the device's team and prefix, and builds, installs and starts nothing")
    func probeRunnerBuilt() async throws {
        let fixture = try RunnerHome()
        defer { fixture.remove() }
        let products = try fixture.build().appendingPathComponent("derived/Build/Products")
        try FileManager.default.createDirectory(at: products, withIntermediateDirectories: true)
        try Data().write(to: products.appendingPathComponent("OffsiderRunner_iphoneos27.0-arm64.xctestrun"))

        let facts = await IOSDeviceDoctorProbe(host: fixture.host, xcodeTeams: { [] }, hid: HIDRecorder(.ready).probe).run(udid: IOSDeviceFixtures.phone).facts

        #expect(facts.runnerBuild == .built(team: "ABCDE12345", prefix: "com.mpalmes.offsider"))
        #expect(facts.runnerTrust == .unknown)
        #expect(!fixture.devicectl.calls.contains { $0.contains("install") || $0.contains("launch") }, "nothing reaches the device's apps")
        let cache = XcodeRunnerBuilder.defaultCacheRoot(home: fixture.home)
        #expect(try FileManager.default.contentsOfDirectory(atPath: cache.path).allSatisfy { !$0.hasSuffix(".lock") }, "no build was started")
    }

    @Test("no cached build for the allowance's prefix is a warning; a build under the default prefix does not count")
    func probeRunnerNotBuilt() async throws {
        let fixture = try RunnerHome(environment: [:])
        defer { fixture.remove() }
        _ = try fixture.build()
        let probe = IOSDeviceDoctorProbe(host: fixture.host, xcodeTeams: { [] }, hid: HIDRecorder(.ready).probe, allowance: Self.allowance(prefix: "dev.offsider.abcde12345"))

        let facts = await probe.run(udid: IOSDeviceFixtures.phone).facts

        #expect(facts.runnerBuild == .notBuilt(team: "ABCDE12345", prefix: "dev.offsider.abcde12345", needsPerson: false), "a prefix sealed in the allowance needs no Touch ID")
        #expect(IOSDeviceDoctorRules.checks(facts).first { $0.id == .iosDeviceRunnerBuild }?.status == .warn)
    }

    @Test("a last build another team's App ID stopped fails with the devices add command that saves a prefix")
    func probeRunnerAppIDTaken() async throws {
        let fixture = try RunnerHome(environment: [:])
        defer { fixture.remove() }
        try Data(try IOSDeviceFixtures.data("xcodebuild-runner-app-id-taken.log")).write(to: try fixture.build().appendingPathComponent("build.log"))
        let probe = IOSDeviceDoctorProbe(host: fixture.host, xcodeTeams: { [] }, hid: HIDRecorder(.ready).probe, allowance: Self.allowance())

        let facts = await probe.run(udid: IOSDeviceFixtures.phone).facts

        let fix = "offsider devices add --device \(IOSDeviceFixtures.phone) --test-device --team ABCDE12345 --runner-prefix dev.offsider.abcde12345"
        #expect(facts.runnerBuild == .appIDTaken(appID: "com.mpalmes.offsider.runner", team: "ABCDE12345", fix: fix))
        let check = try #require(IOSDeviceDoctorRules.checks(facts).first { $0.id == .iosDeviceRunnerBuild })
        #expect(check.status == .fail && check.hint?.contains(fix) == true)
    }

    @Test("a recorded untrusted certificate for this team fails runner-trust; one for another team is stale and ignored")
    func probeRunnerUntrusted() async throws {
        let fixture = try RunnerHome()
        defer { fixture.remove() }
        let store = RunnerSessionStore(root: fixture.host.privateRoot)
        try store.writeFailure(RunnerStartFailure(kind: .certificateNotTrusted, team: "ABCDE12345", at: Date()), udid: IOSDeviceFixtures.phone)
        let probe = IOSDeviceDoctorProbe(host: fixture.host, xcodeTeams: { [] }, hid: HIDRecorder(.ready).probe)

        let facts = await probe.run(udid: IOSDeviceFixtures.phone).facts
        #expect(facts.runnerTrust == .untrusted(team: "ABCDE12345"))
        #expect(IOSDeviceDoctorRules.checks(facts).first { $0.id == .iosDeviceRunnerTrust }?.status == .fail)

        try store.writeFailure(RunnerStartFailure(kind: .certificateNotTrusted, team: "ZYXWV98765", at: Date()), udid: IOSDeviceFixtures.phone)
        #expect(await probe.run(udid: IOSDeviceFixtures.phone).facts.runnerTrust == .unknown)
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
