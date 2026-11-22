import CoreFoundation
import Foundation
@testable import OffsiderCore
import Testing

/// Records each key it is asked for, so a test can prove a gate reads one key and no more.
final class RecordingManagedPreferences: ManagedPreferenceSource, @unchecked Sendable {
    private let lock = NSLock()
    private var asked: [String] = []
    let values: [String: ManagedPreferenceValue]

    init(_ values: [String: ManagedPreferenceValue] = [:]) {
        self.values = values
    }

    var keys: [String] { lock.withLock { asked } }

    func forcedValue(forKey key: String) -> ManagedPreferenceValue? {
        lock.withLock { asked.append(key) }
        return values[key]
    }

    func forcedKeys() -> [String] { Array(values.keys) }
}

@Suite("Managed ceilings")
struct ManagedCeilingsTests {
    static let wrongTypes: [ManagedPreferenceValue] = [.strings(["yes"]), .integer(1), .unreadable]

    static func ceilings(_ values: [String: ManagedPreferenceValue]) -> ManagedCeilings {
        ManagedCeilings.read(from: FakeManagedPreferences(values: values))
    }

    static func policy(_ values: [String: ManagedPreferenceValue], entries: [DeviceAllowance] = []) -> PhysicalDevicePolicy {
        PhysicalDevicePolicy(managed: ManagedDevicePolicy.read(from: FakeManagedPreferences(values: values)), list: DeviceAllowList(entries: entries))
    }

    @Test("a profile's value reads as a boolean, a whole number or strings, and anything else as unreadable")
    func plistValues() {
        #expect(LiveManagedPreferences.value(of: kCFBooleanTrue) == .bool(true))
        #expect(LiveManagedPreferences.value(of: kCFBooleanFalse) == .bool(false))
        #expect(LiveManagedPreferences.value(of: NSNumber(value: 7)) == .integer(7))
        #expect(LiveManagedPreferences.value(of: NSNumber(value: 1)) == .integer(1))
        #expect(LiveManagedPreferences.value(of: NSNumber(value: 7.5)) == .unreadable)
        #expect(LiveManagedPreferences.value(of: NSNumber(value: 7.0)) == .unreadable)
        #expect(LiveManagedPreferences.value(of: ["ABCDE12345"] as NSArray) == .strings(["ABCDE12345"]))
        #expect(LiveManagedPreferences.value(of: [] as NSArray) == .strings([]))
        #expect(LiveManagedPreferences.value(of: ["a", 1] as NSArray) == .unreadable)
        #expect(LiveManagedPreferences.value(of: "true" as NSString) == .unreadable)
        #expect(LiveManagedPreferences.value(of: ["forceMasks": true] as NSDictionary) == .unreadable)
    }

    @Test("a switch that is not forced, or forced to its open value, refuses nothing", arguments: ManagedCeilings.Switch.allCases)
    func unforcedSwitch(item: ManagedCeilings.Switch) {
        #expect(Self.ceilings([:]).refusal(item) == nil)
        #expect(!Self.ceilings([:]).present)
        let open = Self.ceilings([item.key: .bool(!item.restrictsWhen)])
        #expect(open.refusal(item) == nil)
        #expect(open.present)
        #expect(open.unreadableKeys.isEmpty)
    }

    @Test("a switch forced to its strict value refuses, naming the organisation and the key", arguments: ManagedCeilings.Switch.allCases)
    func forcedSwitch(item: ManagedCeilings.Switch) throws {
        let refusal = try #require(Self.ceilings([item.key: .bool(item.restrictsWhen)]).refusal(item))
        #expect(refusal.hasPrefix("your organisation "))
        #expect(refusal.hasSuffix("(\(item.key))"))
        for other in ManagedCeilings.Switch.allCases where other != item {
            #expect(Self.ceilings([item.key: .bool(item.restrictsWhen)]).refusal(other) == nil)
        }
    }

    @Test("a switch forced to the wrong type reads as its strict value, names the key and refuses every phone", arguments: ManagedCeilings.Switch.allCases)
    func wrongTypedSwitch(item: ManagedCeilings.Switch) throws {
        for value in Self.wrongTypes {
            let read = Self.ceilings([item.key: value])
            #expect(read.unreadableKeys == [item.key])
            #expect(try #require(read.refusal(item)).hasSuffix("(\(item.key))"))
            let policy = Self.policy([item.key: value], entries: [PolicyFixtures.entry(apps: ["com.example.app"])])
            #expect(policy.decision(platform: .ios, key: PolicyFixtures.phone, now: PolicyFixtures.now) == .refused(.managedUnreadable(item.key)))
        }
    }

    @Test("maxAllowanceDays reads a whole number of days from 1; anything else is unreadable and refuses every phone")
    func allowanceDays() {
        #expect(Self.ceilings([:]).allowanceCap == nil)
        let week = Self.ceilings([ManagedCeilings.maxAllowanceDaysKey: .integer(7)])
        #expect(week.maxAllowanceDays == 7 && week.allowanceCap == TimeInterval(7 * 86_400) && week.unreadableKeys.isEmpty)
        for value: ManagedPreferenceValue in [.integer(0), .integer(-3), .integer(ManagedCeilings.longestAllowanceDays + 1), .bool(true), .strings(["7"]), .unreadable] {
            let read = Self.ceilings([ManagedCeilings.maxAllowanceDaysKey: value])
            #expect(read.allowanceCap == nil)
            #expect(read.unreadableKeys == [ManagedCeilings.maxAllowanceDaysKey])
            let policy = Self.policy([ManagedCeilings.maxAllowanceDaysKey: value], entries: [PolicyFixtures.entry()])
            #expect(policy.decision(platform: .ios, key: PolicyFixtures.phone, now: PolicyFixtures.now) == .refused(.managedUnreadable(ManagedCeilings.maxAllowanceDaysKey)))
        }
    }

    @Test("allowedTeamIDs permits only the listed teams, without case; an empty list permits none, and a wrong type refuses every team")
    func teams() throws {
        #expect(Self.ceilings([:]).teamRefusal("ABCDE12345") == nil)
        let listed = Self.ceilings([ManagedCeilings.allowedTeamIDsKey: .strings([" abcde12345 "])])
        #expect(listed.permits(team: "ABCDE12345"))
        #expect(listed.teamRefusal("ZYXWV98765") == "your organisation does not list team ZYXWV98765 (allowedTeamIDs)")
        #expect(!Self.ceilings([ManagedCeilings.allowedTeamIDsKey: .strings([])]).permits(team: "ABCDE12345"))
        let wrong = Self.ceilings([ManagedCeilings.allowedTeamIDsKey: .bool(true)])
        #expect(wrong.unreadableKeys == [ManagedCeilings.allowedTeamIDsKey])
        #expect(try #require(wrong.teamRefusal("ABCDE12345")).hasSuffix("(allowedTeamIDs)"))
    }

    @Test("a gate reads the one key it enforces, and an unforced key leaves it open")
    func gateReadsOneKey() {
        for item in ManagedCeilings.Switch.allCases {
            let source = RecordingManagedPreferences()
            #expect(ManagedGate.$sourceOverride.withValue(source) { ManagedGate.refusal(item) } == nil)
            #expect(source.keys == [item.key])
        }
        let source = RecordingManagedPreferences([ManagedCeilings.allowedTeamIDsKey: .strings(["ABCDE12345"])])
        #expect(ManagedGate.$sourceOverride.withValue(source) { ManagedGate.teamRefusal("ZYXWV98765") } != nil)
        #expect(source.keys == [ManagedCeilings.allowedTeamIDsKey])
    }

    @Test("only the commands and paths a ceiling governs ask for it, so no other command reads a managed key")
    func gateCallSites() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources")
        var callers: Set<String> = []
        for case let file as URL in FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)! where file.pathExtension == "swift" {
            let text = try String(contentsOf: file, encoding: .utf8)
            if text.contains("ManagedGate.") || text.contains("requireManaged(") { callers.insert(file.lastPathComponent) }
        }
        #expect(callers == [
            "Errors.swift",
            "Screenshot.swift", "Type.swift", "Credential.swift", "Login.swift", "UnlockCode.swift", "Wake.swift", "Permission.swift",
            "Runner.swift", "RunnerBuilder.swift", "RNOpen.swift", "AndroidBackend+MetroReverse.swift", "Doctor.swift",
        ])
    }

    @Test("every ceiling key is one this build knows, so forcing it never reads as an unknown key")
    func ceilingKeysAreKnown() {
        let values = Dictionary(uniqueKeysWithValues: ManagedCeilings.Switch.allCases.map { ($0.key, ManagedPreferenceValue.bool(!$0.restrictsWhen)) })
            .merging([ManagedCeilings.maxAllowanceDaysKey: .integer(30), ManagedCeilings.allowedTeamIDsKey: .strings(["ABCDE12345"])]) { $1 }
        #expect(Set(values.keys) == Set(ManagedCeilings.keys))
        let managed = ManagedDevicePolicy.read(from: FakeManagedPreferences(values: values))
        #expect(managed.unknownKeys.isEmpty)
        #expect(managed.unreadableKeys.isEmpty)
        #expect(managed.present)
    }

    @Test("while a ceiling is forced, a test device is a plain allowance unless allowTestDevices says otherwise, and never under requirePinnedApps")
    func testDevices() {
        let masks = ManagedDevicePolicy.read(from: FakeManagedPreferences(values: ["forceMasks": .bool(true)]))
        #expect(masks.testDeviceRefusal == ManagedRefusalText.testDevicesOff)
        let allowed = ManagedDevicePolicy.read(from: FakeManagedPreferences(values: ["forceMasks": .bool(true), "allowTestDevices": .bool(true)]))
        #expect(allowed.testDeviceRefusal == nil)
        let pins = ManagedDevicePolicy.read(from: FakeManagedPreferences(values: ["requirePinnedApps": .bool(true), "allowTestDevices": .bool(true)]))
        #expect(pins.testDeviceRefusal == ManagedCeilings.Switch.requirePinnedApps.refusal)
    }

    @Test("maxAllowanceDays ends an allowance that many days after it was added, whatever its own expiry says")
    func capsExistingAllowances() {
        let never = PolicyFixtures.entry(expires: nil, apps: ["com.example.app"])
        let policy = Self.policy([ManagedCeilings.maxAllowanceDaysKey: .integer(7)], entries: [never])
        let limit = PolicyFixtures.added.addingTimeInterval(7 * 86_400)
        guard case .allowed(let held) = policy.decision(platform: .ios, key: PolicyFixtures.phone, now: PolicyFixtures.now) else {
            Issue.record("an allowance inside the cap was refused")
            return
        }
        #expect(held.expires == limit)
        #expect(policy.decision(platform: .ios, key: PolicyFixtures.phone, now: limit) == .refused(.cappedExpired(limit, days: 7)))
        #expect(DeviceRefusal.cappedExpired(limit, days: 7).explanation.contains("your organisation limits an allowance to 7 days (maxAllowanceDays)"))
        #expect(!DeviceRefusal.cappedExpired(limit, days: 7).isManaged)

        let sooner = PolicyFixtures.entry(apps: ["com.example.app"])
        let short = Self.policy([ManagedCeilings.maxAllowanceDaysKey: .integer(7)], entries: [sooner])
        #expect(short.decision(platform: .ios, key: PolicyFixtures.phone, now: PolicyFixtures.now) == .allowed(sooner))
        #expect(short.decision(platform: .ios, key: PolicyFixtures.phone, now: PolicyFixtures.added.addingTimeInterval(3_600)) == .refused(.expired(sooner.expires!)))
        #expect(Self.policy([:], entries: [never]).decision(platform: .ios, key: PolicyFixtures.phone, now: limit) == .allowed(never))
    }

    @Test("requirePinnedApps refuses an allowance that names no app or pins every app, and leaves a named one alone")
    func pinsRequired() {
        let forced: [String: ManagedPreferenceValue] = ["requirePinnedApps": .bool(true)]
        for apps in [[], [DeviceAllowance.wholeDevicePin], [DeviceAllowance.wholeDevicePin, "com.example.app"]] {
            let entry = PolicyFixtures.entry(.android, key: PolicyFixtures.serial, apps: apps)
            #expect(Self.policy(forced, entries: [entry]).decision(platform: .android, key: PolicyFixtures.serial, now: PolicyFixtures.now) == .refused(.pinsRequired))
            #expect(Self.policy(["requirePinnedApps": .bool(false)], entries: [entry]).decision(platform: .android, key: PolicyFixtures.serial, now: PolicyFixtures.now) == .allowed(entry))
        }
        let named = PolicyFixtures.entry(apps: ["com.example.app"])
        #expect(Self.policy(forced, entries: [named]).decision(platform: .ios, key: PolicyFixtures.phone, now: PolicyFixtures.now) == .allowed(named))
        #expect(DeviceRefusal.pinsRequired.managedKey == "requirePinnedApps")
        #expect(DeviceRefusal.pinsRequired.code == "pins_required")
    }

    @Test("a person's status page says so when the organisation ended an allowance, with the command that allows it again")
    func statusWarnsOnEndedAllowance() {
        let open = PolicyFixtures.entry(.android, key: PolicyFixtures.serial, expires: nil)
        let pins = Self.policy(["requirePinnedApps": .bool(true)], entries: [open])
        #expect(AccessStatusScreen.warning(pins, now: PolicyFixtures.now) == AccessStatusScreen.managedEndedSome)
        let capped = Self.policy(["maxAllowanceDays": .integer(1)], entries: [open])
        #expect(AccessStatusScreen.warning(capped, now: PolicyFixtures.now) == nil)
        #expect(AccessStatusScreen.warning(capped, now: PolicyFixtures.added.addingTimeInterval(2 * 86_400)) == AccessStatusScreen.managedEndedSome)
        let page = AccessStatusScreen.page(pins, now: PolicyFixtures.now, timeZone: TimeZone(identifier: "UTC")!)
        #expect(page.notices.contains { $0.text == AccessStatusScreen.managedEndedSome && $0.command == AccessStatusScreen.allowCommand })
        let expired = Self.policy([:], entries: [PolicyFixtures.entry()])
        #expect(AccessStatusScreen.warning(expired, now: PolicyFixtures.added.addingTimeInterval(7_200)) == nil)
    }

    @Test("an allowance about to be saved is refused for a team, a Metro port, a broad use or a length the organisation does not allow")
    func addRefusals() {
        let policy = Self.policy([
            "allowedTeamIDs": .strings(["ABCDE12345"]), "allowMetroReverse": .bool(false), "requirePinnedApps": .bool(true), "maxAllowanceDays": .integer(7),
        ])
        #expect(policy.addRefusal(apps: ["com.example.app"], lifetime: .some(86_400), team: "ABCDE12345") == nil)
        #expect(policy.addRefusal(team: "ZYXWV98765")?.hasSuffix("(allowedTeamIDs)") == true)
        #expect(policy.addRefusal(metroPorts: [8081])?.hasSuffix("(allowMetroReverse)") == true)
        #expect(policy.addRefusal(apps: [])?.hasSuffix("(requirePinnedApps)") == true)
        #expect(policy.addRefusal(apps: [DeviceAllowance.wholeDevicePin])?.hasSuffix("(requirePinnedApps)") == true)
        #expect(policy.addRefusal(lifetime: .some(nil))?.hasSuffix("(maxAllowanceDays)") == true)
        #expect(policy.addRefusal(lifetime: .some(8 * 86_400))?.hasSuffix("(maxAllowanceDays)") == true)
        #expect(policy.addRefusal(lifetime: .some(7 * 86_400)) == nil)
        #expect(Self.policy([:]).addRefusal(apps: [], lifetime: .some(nil), team: "ZYXWV98765", metroPorts: [8081]) == nil)
    }

    @Test("devices status names every forced ceiling and its value, in text and JSON, and shows the capped expiry")
    func statusListsCeilings() throws {
        let entry = PolicyFixtures.entry(expires: nil, apps: ["com.example.app"])
        let policy = Self.policy([
            "forceMasks": .bool(true), "maxAllowanceDays": .integer(7), "allowSavedLogins": .bool(false), "allowedTeamIDs": .strings(["ABCDE12345"]),
        ], entries: [entry])
        let text = DeviceAccessReport.statusText(policy, now: PolicyFixtures.now, path: "/tmp/list.json")
        #expect(text.contains("Managed policy: masks forced on; allowances last at most 7 days; saved logins off; teams limited to ABCDE12345."))
        let limit = ProcessStamp.timestamp(PolicyFixtures.added.addingTimeInterval(7 * 86_400))
        #expect(text.contains("allowed until \(limit)"))

        let json = try #require(JSONSerialization.jsonObject(with: Data(policy.statusJSON(now: PolicyFixtures.now).utf8)) as? [String: Any])
        let managed = try #require(json["managed"] as? [String: Any])
        #expect(managed["forceMasks"] as? Bool == true)
        #expect(managed["maxAllowanceDays"] as? Int == 7)
        #expect(managed["allowSavedLogins"] as? Bool == false)
        #expect(managed["allowedTeamIDs"] as? [String] == ["ABCDE12345"])
        #expect(managed["allowFileInput"] is NSNull)
        for key in ManagedCeilings.keys { #expect(managed[key] != nil, "devices status --json has no \(key)") }
        let device = try #require((json["devices"] as? [[String: Any]])?.first)
        #expect(device["expires"] as? String == limit)
        #expect(device["active"] as? Bool == true)
    }

    @Test("doctor's managed.policy lists the keys in force, skips on an unmanaged Mac and fails on a key it cannot honour")
    func doctorVerdict() {
        #expect(ManagedDevicePolicy.none.doctorVerdict.status == .skip)
        let forced = ManagedDevicePolicy.read(from: FakeManagedPreferences(values: ["allowPhysicalDevices": .bool(true), "forceMasks": .bool(true), "maxAllowanceDays": .integer(7)]))
        #expect(forced.doctorVerdict.status == .pass)
        #expect(forced.doctorVerdict.detail == "allowPhysicalDevices=true, forceMasks=true, maxAllowanceDays=7")
        let wrong = ManagedDevicePolicy.read(from: FakeManagedPreferences(values: ["forceMasks": .integer(1), "someNewKey": .bool(true)]))
        #expect(wrong.doctorVerdict.status == .fail)
        #expect(wrong.doctorVerdict.detail.contains("forceMasks=unreadable"))
        #expect(wrong.doctorVerdict.detail.contains("someNewKey=unknown"))
    }
}
