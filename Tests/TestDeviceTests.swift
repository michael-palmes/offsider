import ArgumentParser
import Foundation
@testable import Offsider
@testable import OffsiderCore
import Testing

private let wholeEntry = DeviceAllowance(platform: .ios, key: PolicyFixtures.phone, name: "Test iPhone", added: PolicyFixtures.added, expires: nil, apps: [], team: "ABCDE12345", testDevice: true)

@Suite("Test device allowance")
struct TestDeviceAllowanceTests {
    @Test("a test device round-trips, and a list without one encodes exactly as before")
    func roundTrip() throws {
        let list = DeviceAllowList(entries: [wholeEntry])
        #expect(try DeviceAllowList.parse(list.encoded()) == list)
        let plain = DeviceAllowList(entries: [PolicyFixtures.entry()])
        #expect(!String(decoding: plain.encoded(), as: UTF8.self).contains("testDevice"))
    }

    @Test("anything but a lone true refuses the whole file, so a hand edit cannot half-apply", arguments: [
        #"{"version":1,"devices":[{"platform":"ios","id":"00008130-0000000000000ABC","name":"A","added":"2026-09-21T14:13:20Z","expires":null,"apps":[],"testDevice":false}]}"#,
        #"{"version":1,"devices":[{"platform":"ios","id":"00008130-0000000000000ABC","name":"A","added":"2026-09-21T14:13:20Z","expires":null,"apps":[],"testDevice":"true"}]}"#,
        #"{"version":1,"devices":[{"platform":"ios","id":"00008130-0000000000000ABC","name":"A","added":"2026-09-21T14:13:20Z","expires":null,"apps":[],"testDevice":1}]}"#,
        #"{"version":1,"devices":[{"platform":"ios","id":"00008130-0000000000000ABC","name":"A","added":"2026-09-21T14:13:20Z","expires":null,"apps":["com.example.app"],"testDevice":true}]}"#,
    ])
    func refused(text: String) {
        #expect(throws: DeviceAllowListError.self) { try DeviceAllowList.parse(Data(text.utf8)) }
    }

    @Test("a test device may drive what the deny-list refuses everywhere else")
    func widensOnlyTestDevices() {
        let whole = PhysicalDevicePolicy(managed: .none, list: DeviceAllowList(entries: [wholeEntry]))
        for app in ["com.apple.springboard", "com.apple.Preferences", "com.apple.mobilesafari"] {
            #expect(whole.appRefusal(app, on: wholeEntry) == nil)
            #expect(whole.permits(app: app, on: wholeEntry))
            let plain = PolicyFixtures.entry()
            #expect(whole.appRefusal(app, on: plain) != nil)
            #expect(!whole.permits(app: app, on: plain))
        }
    }

    /// (forced policy, driven whole?)
    static let managedCases: [(ManagedDevicePolicy, Bool)] = [
        (.none, true),
        (ManagedDevicePolicy(allowPhysicalDevices: true), false),
        (ManagedDevicePolicy(allowedDeviceIDs: [PolicyFixtures.phone]), false),
        (ManagedDevicePolicy(allowTestDevices: false), false),
        (ManagedDevicePolicy(allowTestDevices: true), true),
        (ManagedDevicePolicy(allowedBundleIDs: ["com.example.app"], allowTestDevices: true), false),
        (ManagedDevicePolicy(deniedBundleIDs: ["com.example.bank"], allowTestDevices: true), false),
    ]

    @Test("any forced key turns a test device off until allowTestDevices is true, and a bundle list always wins", arguments: managedCases)
    func managedCap(managed: ManagedDevicePolicy, whole: Bool) {
        let policy = PhysicalDevicePolicy(managed: managed, list: DeviceAllowList(entries: [wholeEntry]))
        #expect(policy.drivesWhole(wholeEntry) == whole)
        #expect((managed.testDeviceRefusal == nil) == whole)
        #expect((policy.appRefusal("com.apple.springboard", on: wholeEntry) == nil) == whole)
    }

    @Test("only a forced true boolean reads as allowed; a wrong type refuses every device")
    func readsManagedKey() {
        let on = ManagedDevicePolicy.read(from: FakeManagedPreferences(values: [ManagedDevicePolicy.allowTestDevicesKey: .bool(true)]))
        #expect(on.allowTestDevices == true)
        #expect(on.testDeviceRefusal == nil)
        #expect(ManagedDevicePolicy.read(from: FakeManagedPreferences()).allowTestDevices == nil)
        let wrong = ManagedDevicePolicy.read(from: FakeManagedPreferences(values: [ManagedDevicePolicy.allowTestDevicesKey: .strings(["yes"])]))
        #expect(wrong.unreadable)
        #expect(wrong.testDeviceRefusal != nil)
    }

    @Test("status JSON and text name a test device, and say why when managed policy has turned it off")
    func status() throws {
        let free = PhysicalDevicePolicy(managed: .none, list: DeviceAllowList(entries: [wholeEntry]))
        #expect(free.statusJSON(now: PolicyFixtures.now).contains(#""testDevice": true"#))
        #expect(!free.statusJSON(now: PolicyFixtures.now).contains("testDeviceOff"))
        #expect(DeviceAccessReport.statusText(free, now: PolicyFixtures.now, path: "p").contains("test device, whole device"))

        let managed = PhysicalDevicePolicy(managed: ManagedDevicePolicy(allowPhysicalDevices: true), list: DeviceAllowList(entries: [wholeEntry]))
        let json = managed.statusJSON(now: PolicyFixtures.now)
        #expect(json.contains(#""testDevice": true"#))
        #expect(json.contains(#""testDeviceOff": "managed policy does not allow test devices on this Mac""#))
        #expect(DeviceAccessReport.statusText(managed, now: PolicyFixtures.now, path: "p").contains("managed policy does not allow"))
    }

    @Test("the driving line says it on every line, in full for an agent; off under managed policy it says nothing wider")
    func driving() {
        #expect(CommandScope.banner(for: wholeEntry, managed: false, wholeDevice: true).contains("as a test device, whole device"))
        #expect(!CommandScope.banner(for: wholeEntry, managed: true, wholeDevice: false).contains("whole device"))
        let person = CommandScope.personBanner(
            for: wholeEntry, managed: false, wholeDevice: true, now: PolicyFixtures.now, timeZone: TimeZone(identifier: "UTC")!, canvas: Canvas(columns: 120, style: .detect(isTerminal: false))
        )
        #expect(person.contains("test device, whole device"))
    }
}

@Suite("devices add --test-device", .serialized)
@MainActor
struct TestDeviceAddTests {
    static let policy = PhysicalDevicePolicy(managed: .none, list: .empty)
    static let apps = [InstalledApp(id: "com.example.app", name: "Example")]

    @Test("the row comes last, is never chosen for you, and a managed Mac is not offered it", arguments: [true, false])
    func menuRow(listed: Bool) {
        let menu = DeviceAccessAllow.appMenu(listed ? Self.apps : [], platform: .ios, policy: Self.policy, profile: nil, front: nil)
        #expect(menu.choices.last == .testDevice)
        #expect(menu.choices[menu.selected] != .testDevice)
        #expect(menu.rows().last?.recommended == false)

        let managed = PhysicalDevicePolicy(managed: ManagedDevicePolicy(allowPhysicalDevices: true), list: .empty)
        #expect(!DeviceAccessAllow.appMenu(Self.apps, platform: .ios, policy: managed, profile: nil, front: nil).choices.contains(.testDevice))
    }

    @Test("the question starts on the answer that stops")
    func questionDefaultsToStop() {
        #expect(DeviceAccessAllow.personalRows[0].columns == [AllowScreen.personalYes])
        #expect(DeviceAccessAllow.personalNoIndex != 0)
    }

    @Test("Until removed comes first for a test device, and every other allowance keeps 12 hours")
    func expiry() {
        let test = DeviceAccessAllow.expiryRows(testDevice: true)
        #expect(test.options[test.recommended].value == "never")
        #expect(test.options.count == DeviceAccessAllow.expiryOptions.count)
        let plain = DeviceAccessAllow.expiryRows(testDevice: false)
        #expect(plain.options[plain.recommended].value == "12h")
    }

    @Test("--test-device with --app is a usage error")
    func flagWithApp() {
        #expect(throws: (any Error).self) { try DeviceAccessAllow.parse(["--test-device", "--app", "com.example.app"]) }
    }

    @Test("without a terminal it fails like any add, writing nothing")
    func needsTerminal() async throws {
        let home = try makePolicyHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let command = try DeviceAccessAllow.parse(["--test-device", "--device", PolicyFixtures.phone])
        await #expect(throws: (any Error).self) {
            try await PersonPresence.$terminal.withValue({ false }) {
                _ = try await command.perform(context: DeviceAccessCommandTests.context(home: home, seal: MemorySeal()))
            }
        }
        #expect(!FileManager.default.fileExists(atPath: DeviceAccessCommandTests.file(home)))
    }

    @Test("choosing the row and saying nothing is personal saves it, until removed by default, after Touch ID")
    func saved() async throws {
        let home = try makePolicyHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let presence = RecordingPresence()
        // Device, the row (Any app, Type, Test device), "No, nothing personal", then the first expiry row.
        _ = try await DeviceAccessCommandTests.allow(["--team", "ABCDE12345"], answers: ["1", "3", "2", "1"], context: { terminal in
            DeviceAccessCommandTests.context(home: home, seal: MemorySeal(), terminal: terminal)
        }, presence: presence)
        let entry = try #require(try DeviceAccessCommandTests.entries(home).first)
        #expect(entry.testDevice)
        #expect(entry.apps.isEmpty)
        #expect(entry.expires == nil)
    }

    @Test("answering that something is personal saves nothing")
    func stopped() async throws {
        let home = try makePolicyHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        await #expect(throws: (any Error).self) {
            _ = try await DeviceAccessCommandTests.allow(["--team", "ABCDE12345"], answers: ["1", "3", "1"], context: { terminal in
                DeviceAccessCommandTests.context(home: home, seal: MemorySeal(), terminal: terminal)
            })
        }
        #expect(try DeviceAccessCommandTests.entries(home).isEmpty)
    }
}
