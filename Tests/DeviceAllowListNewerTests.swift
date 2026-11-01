import Foundation
import OffsiderCore
import Testing
@testable import Offsider

@Suite("Allow-list entries a newer Offsider wrote")
@MainActor
struct DeviceAllowListNewerTests {
    nonisolated static let held = PolicyFixtures.serial
    nonisolated static let other = "R58M999XYZ"

    nonisolated static func row(_ id: String, name: String = "Test Pixel", extra: String = "") -> String {
        #"{"platform":"android","id":"\#(id)","name":"\#(name)","added":"2026-09-21T14:13:20Z","expires":null,"apps":["com.example.app"]\#(extra)}"#
    }

    nonisolated static let stranger = #","newLimit":{"maxTaps":3,"strict":true,"note":null}"#

    nonisolated static func file(_ rows: String...) -> Data {
        Data(#"{"version":1,"devices":[\#(rows.joined(separator: ","))]}"#.utf8)
    }

    static func policy(_ data: Data = file(row(held, extra: stranger), row(other, name: "Other Pixel"))) throws -> PhysicalDevicePolicy {
        PhysicalDevicePolicy(managed: .none, list: try DeviceAllowList.parse(data))
    }

    @Test("a stranger key on one device refuses that device and leaves the others working")
    func blocksOnlyThatDevice() throws {
        let policy = try Self.policy()
        #expect(policy.decision(platform: .android, key: Self.held) == .refused(.newerEntry("newLimit")))
        guard case .allowed(let other) = policy.decision(platform: .android, key: Self.other) else {
            Issue.record("the other device was refused")
            return
        }
        #expect(other.name == "Other Pixel")
        #expect(policy.list.entry(platform: .android, key: Self.held) == nil, "the held entry must never be read as an allowance")
    }

    @Test("a stranger key on a test device holds it back, so it never drives whole past a limit this build cannot read")
    func heldTestDeviceDrivesNothing() throws {
        let policy = try Self.policy(Self.file(#"{"platform":"android","id":"\#(Self.held)","name":"Test Pixel","added":"2026-09-21T14:13:20Z","expires":null,"apps":[],"testDevice":true,"newLimit":1}"#))
        #expect(policy.decision(platform: .android, key: Self.held) == .refused(.newerEntry("newLimit")))
        #expect(policy.list.entries.isEmpty)
    }

    @Test("the refusal comes after managed policy and a broken seal, so those still stop every device")
    func strongerRefusalsFirst() throws {
        let list = try DeviceAllowList.parse(Self.file(Self.row(Self.held, extra: Self.stranger), Self.row(Self.other)))
        let tampered = PhysicalDevicePolicy(managed: .none, list: list, sealIntact: false)
        #expect(tampered.decision(platform: .android, key: Self.held) == .refused(.listChanged))
        #expect(tampered.decision(platform: .android, key: Self.other) == .refused(.listChanged))
        let off = PhysicalDevicePolicy(managed: ManagedDevicePolicy(allowPhysicalDevices: false), list: list)
        #expect(off.decision(platform: .android, key: Self.held) == .refused(.managedOff))
    }

    @Test("what stays strict refuses the whole file", arguments: [
        #"{"version":1,"devices":[],"newTop":1}"#,
        #"{"version":2,"devices":[\#(row(held, extra: stranger))]}"#,
        #"{"version":1,"devices":[{"platform":"android","name":"No id","newLimit":1}]}"#,
        #"{"version":1,"devices":[{"platform":"android","id":"emulator-5554","newLimit":1}]}"#,
        #"{"version":1,"devices":[{"platform":"tablet","id":"R58M123ABC","newLimit":1}]}"#,
        #"{"version":1,"devices":[\#(row(held, extra: stranger)),\#(row(held))]}"#,
        #"{"version":1,"devices":[\#(row(held, extra: stranger)),{"platform":"android","id":"R58M999XYZ"}]}"#,
    ])
    func wholeFileStaysStrict(text: String) {
        #expect(throws: DeviceAllowListError.self) { try DeviceAllowList.parse(Data(text.utf8)) }
    }

    @Test("a known field a newer build changed does not matter once the entry is held, and a bad name falls back to the id")
    func heldEntryReadsOnlyWhichDevice() throws {
        let list = try DeviceAllowList.parse(Data(#"{"version":1,"devices":[{"platform":"android","id":"\#(Self.held)","name":5,"apps":{"any":true},"newLimit":1}]}"#.utf8))
        #expect(list.newer.map(\.name) == [Self.held])
        #expect(list.newer.map(\.unknownKeys) == [["newLimit"]])
    }

    @Test("a write for another device keeps the entry as written, and a newer build reads the same values back")
    func writesBackAsItCame() throws {
        let list = try DeviceAllowList.parse(Self.file(Self.row(Self.held, extra: Self.stranger), Self.row(Self.other)))
        let later = PolicyFixtures.now.addingTimeInterval(100_000)
        let changed = list.pruned(now: later).removing(platform: .android, key: Self.other)
        let object = try #require(try JSONSerialization.jsonObject(with: changed.encoded()) as? [String: Any])
        let rows = try #require(object["devices"] as? [[String: Any]])
        #expect(rows.count == 1)
        let limit = try #require(rows[0]["newLimit"] as? [String: Any])
        #expect(limit["maxTaps"] as? Int == 3)
        #expect(limit["strict"] as? Bool == true)
        #expect(limit["note"] is NSNull)
        #expect(rows[0]["apps"] as? [String] == ["com.example.app"])
        #expect(try DeviceAllowList.parse(changed.encoded()) == changed)
    }

    @Test("allowing or removing the held device itself replaces its entry")
    func sameDeviceReplaces() throws {
        let list = try DeviceAllowList.parse(Self.file(Self.row(Self.held, extra: Self.stranger)))
        let added = list.adding(PolicyFixtures.entry(.android, key: Self.held, apps: []))
        #expect(added.newer.isEmpty && added.entries.count == 1)
        #expect(list.removing(platform: .android, key: Self.held).isEmpty)
    }

    @Test("the message names the cause and the fix, for a person and for an agent")
    func messageWording() {
        let refusal = DeviceRefusal.newerEntry("newLimit")
        let person = CLIError.deviceNotAllowed(name: "Test Pixel", key: Self.held, refusal: refusal, audience: .person)
        #expect(person.reason == .deviceNotAllowed)
        #expect(person.userFacingDescription == "Test Pixel (\(Self.held)) is a physical device and a newer Offsider wrote its allow-list entry, with a setting this one cannot read (\"newLimit\"), so nothing was sent to it. Update Offsider: brew upgrade offsider.")
        #expect(person.hint == "brew upgrade offsider")
        let agent = CLIError.deviceNotAllowed(name: "Test Pixel", key: Self.held, refusal: refusal, audience: .agent)
        #expect(agent.userFacingDescription.hasSuffix("so nothing was sent to it. Ask the user to run `brew upgrade offsider` in their own terminal."))
    }

    @Test("devices status shows the held device as refused, in text and JSON, beside the working one")
    func statusIsHonest() throws {
        let policy = try Self.policy()
        let text = DeviceAccessReport.statusText(policy, now: PolicyFixtures.now, path: "/tmp/list.json")
        #expect(text.contains("android  \(Self.held)  Test Pixel: refused: a newer Offsider wrote its allow-list entry"))
        #expect(text.contains("android  \(Self.other)  Other Pixel: allowed until removed"))

        let object = try #require(try JSONSerialization.jsonObject(with: Data(policy.statusJSON(now: PolicyFixtures.now).utf8)) as? [String: Any])
        let rows = try #require(object["devices"] as? [[String: Any]])
        let held = try #require(rows.first { $0["id"] as? String == Self.held })
        #expect(held["active"] as? Bool == false)
        #expect(held["refusal"] as? String == "newer_entry")
        #expect(held["unknownKeys"] as? [String] == ["newLimit"])
        #expect(rows.first { $0["id"] as? String == Self.other }?["active"] as? Bool == true)

        let only = try #require(try JSONSerialization.jsonObject(with: Data(policy.statusJSON(now: PolicyFixtures.now, only: (.android, Self.held)).utf8)) as? [String: Any])
        #expect(only["allowed"] as? Bool == false)
        #expect(only["refusal"] as? String == "newer_entry")
    }

    @Test("a person's status page warns and names the update")
    func statusPageWarns() throws {
        let policy = try Self.policy()
        #expect(AccessStatusScreen.warning(policy, now: PolicyFixtures.now) == "Test Pixel needs a newer Offsider.")
        let page = AccessStatusScreen.page(policy, now: PolicyFixtures.now, timeZone: .gmt)
        #expect(page.notices.contains { $0.command == NewerDeviceEntry.updateCommand })
        #expect(AccessStatusScreen.allowed(policy, now: PolicyFixtures.now).map(\.key) == [Self.other])
    }

    @Test("doctor fails the one device with the cause and the fix, not as a device no one allowed")
    func doctorIsHonest() throws {
        let decision = try Self.policy().decision(platform: .android, key: Self.held)
        let check = DoctorPolicy(platform: .android, key: Self.held, decision: decision, managed: false).check
        #expect(check.status == .fail)
        #expect(check.detail.contains("A newer Offsider wrote \(Self.held)'s allow-list entry"))
        #expect(check.detail.contains("newer_entry"))
        #expect(check.hint?.contains("brew upgrade offsider") == true)
    }

    @Test("a held entry still counts as a file with devices, so it needs the seal")
    func sealCoversHeldEntries() throws {
        let data = Self.file(Self.row(Self.held, extra: Self.stranger))
        let snapshot = DeviceAllowListSnapshot(list: try DeviceAllowList.parse(data), data: data)
        #expect(!MemorySeal().isIntact(snapshot))
    }

    @Test("devices remove takes a held entry off and names it, and leaves the others sealed")
    func removeHeldEntry() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("offsider-newer-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(atPath: home) }
        let seal = MemorySeal()
        let store = DeviceAllowListStore(directory: UserConfigDirectory(home: home))
        let list = try DeviceAllowList.parse(Self.file(Self.row(Self.held, extra: Self.stranger), Self.row(Self.other)))
        try store.update({ _ in list }, commit: { try seal.seal($0) })

        let context = DeviceAccessCommandTests.context(home: home, seal: seal)
        let text = try await DeviceAccessRemove.parse(["--device", Self.held]).perform(context: context)
        #expect(text.hasPrefix("Removed Test Pixel (\(Self.held)) from the allow-list"))
        #expect(!text.contains("changed outside Offsider"))
        let left = try store.load()
        #expect(left.list.newer.isEmpty && left.list.entries.map(\.key) == [Self.other])
        #expect(seal.isIntact(left))
    }
}
