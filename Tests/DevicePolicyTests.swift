import CoreFoundation
import Darwin
import Foundation
@testable import OffsiderCore
import Testing

/// A fresh home with no `.config`, removed by the caller.
func makePolicyHome() throws -> String {
    let path = (NSTemporaryDirectory() as NSString).appendingPathComponent("offsider-policy-\(UUID().uuidString)")
    try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    return URL(fileURLWithPath: path).resolvingSymlinksInPath().path
}

enum PolicyFixtures {
    static let phone = "00008130-0000000000000ABC"
    static let serial = "R58M123ABC"
    static let added = Date(timeIntervalSince1970: 1_790_000_000)
    static let now = added.addingTimeInterval(60)

    static func entry(_ platform: DevicePlatform = .ios, key: String = phone, expires: Date? = added.addingTimeInterval(3_600), apps: [String] = []) -> DeviceAllowance {
        DeviceAllowance(platform: platform, key: key, name: "Test iPhone", added: added, expires: expires, apps: apps)
    }
}

struct FakeManagedPreferences: ManagedPreferenceSource {
    var values: [String: ManagedPreferenceValue] = [:]

    func forcedValue(forKey key: String) -> ManagedPreferenceValue? { values[key] }
}

@Suite("Device allow-list")
struct DeviceAllowListTests {
    @Test("a list round-trips through its file, with keys in schema order and whole-second times")
    func roundTrip() throws {
        let list = DeviceAllowList(entries: [
            PolicyFixtures.entry(apps: ["com.mpalmes.offsider.playground"]),
            PolicyFixtures.entry(.android, key: PolicyFixtures.serial, expires: nil),
        ])
        let data = list.encoded()
        #expect(try DeviceAllowList.parse(data) == list)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("\"expires\": null"))
        let order = ["\"platform\"", "\"id\"", "\"name\"", "\"added\"", "\"expires\"", "\"apps\""].compactMap { text.range(of: $0)?.lowerBound }
        #expect(order == order.sorted() && order.count == 6)
    }

    @Test("strict parsing refuses the whole file for any drift", arguments: [
        #"{"version":2,"devices":[]}"#,
        #"{"version":true,"devices":[]}"#,
        #"{"version":1,"devices":[],"extra":1}"#,
        #"{"version":1}"#,
        #"[]"#,
        #"{"version":1,"devices":[{"platform":"ios","id":"00008130-0000000000000ABC","name":"A","added":"2026-09-21T14:13:20Z","expires":null,"apps":[],"note":"x"}]}"#,
        #"{"version":1,"devices":[{"platform":"ios","id":"00008130-0000000000000abc","name":"A","added":"2026-09-21T14:13:20Z","expires":null,"apps":[]}]}"#,
        #"{"version":1,"devices":[{"platform":"ios","id":"ABCDEF00-0000-4000-8000-00000000ABCD","name":"A","added":"2026-09-21T14:13:20Z","expires":null,"apps":[]}]}"#,
        #"{"version":1,"devices":[{"platform":"android","id":"emulator-5554","name":"A","added":"2026-09-21T14:13:20Z","expires":null,"apps":[]}]}"#,
        #"{"version":1,"devices":[{"platform":"android","id":"192.168.1.5:5555","name":"A","added":"2026-09-21T14:13:20Z","expires":null,"apps":[]}]}"#,
        #"{"version":1,"devices":[{"platform":"android","id":"R58M123ABC","name":"A","added":"yesterday","expires":null,"apps":[]}]}"#,
        #"{"version":1,"devices":[{"platform":"android","id":"R58M123ABC","name":"A","added":"2026-09-21T14:13:20Z","expires":5,"apps":[]}]}"#,
        #"{"version":1,"devices":[{"platform":"android","id":"R58M123ABC","name":"A","added":"2026-09-21T14:13:20Z","expires":null,"apps":["not an id"]}]}"#,
        #"{"version":1,"devices":[{"platform":"android","id":"R58M123ABC","name":"A","added":"2026-09-21T14:13:20Z","expires":null,"apps":["a.b","a.b"]}]}"#,
        #"{"version":1,"devices":[{"platform":"android","id":"R58M123ABC","name":"","added":"2026-09-21T14:13:20Z","expires":null,"apps":[]}]}"#,
        #"{"version":1,"devices":[{"platform":"android","id":"R58M123ABC","name":"A","added":"2026-09-21T14:13:20Z","expires":null,"apps":[]},{"platform":"android","id":"R58M123ABC","name":"B","added":"2026-09-21T14:13:20Z","expires":null,"apps":[]}]}"#,
    ])
    func strictParse(text: String) {
        #expect(throws: DeviceAllowListError.self) { try DeviceAllowList.parse(Data(text.utf8)) }
    }

    @Test("an iPhone's runner team round-trips, and a list without teams encodes exactly as before")
    func teamRoundTrip() throws {
        let withTeam = DeviceAllowance(platform: .ios, key: PolicyFixtures.phone, name: "Test iPhone", added: PolicyFixtures.added, expires: nil, apps: [], team: "ABCDE12345")
        let list = DeviceAllowList(entries: [withTeam])
        let parsed = try DeviceAllowList.parse(list.encoded())
        #expect(parsed.entries.first?.team == "ABCDE12345")
        #expect(parsed == list)

        let legacy = #"{"version":1,"devices":[{"platform":"ios","id":"00008130-0000000000000ABC","name":"A","added":"2026-09-21T14:13:20Z","expires":null,"apps":[]}]}"#
        let old = try DeviceAllowList.parse(Data(legacy.utf8))
        #expect(old.entries.first?.team == nil)
        #expect(!String(decoding: old.encoded(), as: UTF8.self).contains("team"))
        #expect(try DeviceAllowList.parse(old.encoded()) == old)
    }

    @Test("a team that is not 10 letters or digits, or a team on an Android entry, refuses the file", arguments: [
        #"{"version":1,"devices":[{"platform":"ios","id":"00008130-0000000000000ABC","name":"A","added":"2026-09-21T14:13:20Z","expires":null,"apps":[],"team":"ABC"}]}"#,
        #"{"version":1,"devices":[{"platform":"ios","id":"00008130-0000000000000ABC","name":"A","added":"2026-09-21T14:13:20Z","expires":null,"apps":[],"team":"ABCDE-1234"}]}"#,
        #"{"version":1,"devices":[{"platform":"ios","id":"00008130-0000000000000ABC","name":"A","added":"2026-09-21T14:13:20Z","expires":null,"apps":[],"team":12345}]}"#,
        #"{"version":1,"devices":[{"platform":"android","id":"R58M123ABC","name":"A","added":"2026-09-21T14:13:20Z","expires":null,"apps":[],"team":"ABCDE12345"}]}"#,
    ])
    func teamRefused(text: String) {
        #expect(throws: DeviceAllowListError.self) { try DeviceAllowList.parse(Data(text.utf8)) }
    }

    @Test("a phone's Metro ports round-trip, and a list without them encodes exactly as before")
    func metroPortsRoundTrip() throws {
        let phone = DeviceAllowance(platform: .android, key: PolicyFixtures.serial, name: "Test Pixel", added: PolicyFixtures.added, expires: nil, apps: [], metroPorts: [8081, 8742])
        let list = DeviceAllowList(entries: [phone])
        let parsed = try DeviceAllowList.parse(list.encoded())
        #expect(parsed.entries.first?.metroPorts == [8081, 8742])
        #expect(parsed == list)

        let without = DeviceAllowList(entries: [PolicyFixtures.entry(.android, key: PolicyFixtures.serial)])
        #expect(!String(decoding: without.encoded(), as: UTF8.self).contains("metroPorts"))
    }

    @Test("Metro ports on an iPhone, adb's or an emulator's port, a low port, a repeat, disorder or a flag refuse the file", arguments: [
        #"{"version":1,"devices":[{"platform":"ios","id":"00008130-0000000000000ABC","name":"A","added":"2026-09-21T14:13:20Z","expires":null,"apps":[],"metroPorts":[8081]}]}"#,
        #"{"version":1,"devices":[{"platform":"android","id":"R58M123ABC","name":"A","added":"2026-09-21T14:13:20Z","expires":null,"apps":[],"metroPorts":[5037]}]}"#,
        #"{"version":1,"devices":[{"platform":"android","id":"R58M123ABC","name":"A","added":"2026-09-21T14:13:20Z","expires":null,"apps":[],"metroPorts":[5555]}]}"#,
        #"{"version":1,"devices":[{"platform":"android","id":"R58M123ABC","name":"A","added":"2026-09-21T14:13:20Z","expires":null,"apps":[],"metroPorts":[22]}]}"#,
        #"{"version":1,"devices":[{"platform":"android","id":"R58M123ABC","name":"A","added":"2026-09-21T14:13:20Z","expires":null,"apps":[],"metroPorts":[8081,8081]}]}"#,
        #"{"version":1,"devices":[{"platform":"android","id":"R58M123ABC","name":"A","added":"2026-09-21T14:13:20Z","expires":null,"apps":[],"metroPorts":[8742,8081]}]}"#,
        #"{"version":1,"devices":[{"platform":"android","id":"R58M123ABC","name":"A","added":"2026-09-21T14:13:20Z","expires":null,"apps":[],"metroPorts":[true]}]}"#,
        #"{"version":1,"devices":[{"platform":"android","id":"R58M123ABC","name":"A","added":"2026-09-21T14:13:20Z","expires":null,"apps":[],"metroPorts":[8081.5]}]}"#,
        #"{"version":1,"devices":[{"platform":"android","id":"R58M123ABC","name":"A","added":"2026-09-21T14:13:20Z","expires":null,"apps":[],"metroPorts":[]}]}"#,
    ])
    func metroPortsRefused(text: String) {
        #expect(throws: DeviceAllowListError.self) { try DeviceAllowList.parse(Data(text.utf8)) }
    }

    @Test("an expired entry stays in the file but is not active, and pruning drops it")
    func expiry() {
        let list = DeviceAllowList(entries: [PolicyFixtures.entry(expires: PolicyFixtures.added)])
        #expect(list.entry(platform: .ios, key: PolicyFixtures.phone) != nil)
        #expect(list.entry(platform: .ios, key: PolicyFixtures.phone, now: PolicyFixtures.now) == nil)
        #expect(list.pruned(now: PolicyFixtures.now).entries.isEmpty)
    }

    @Test("the store writes a 0600 file in a 0700 folder and reads it back; a missing file is an empty list")
    func storeWrites() throws {
        let home = try makePolicyHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let store = DeviceAllowListStore(directory: UserConfigDirectory(home: home))
        #expect(try store.load() == .missing)
        try store.update { $0.list.adding(PolicyFixtures.entry()) }
        let folder = home + "/.config/offsider"
        let file = folder + "/allowed-devices.json"
        #expect(try FileManager.default.attributesOfItem(atPath: file)[.posixPermissions] as? Int == 0o600)
        #expect(try FileManager.default.attributesOfItem(atPath: folder)[.posixPermissions] as? Int == 0o700)
        #expect(try store.load().list.entries == [PolicyFixtures.entry()])
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder).sorted() == [".allowed-devices.lock", "allowed-devices.json"])
    }

    @Test("a symlinked, group-readable or FIFO allow-list is refused, and the FIFO without hanging")
    func unsafeFilesRefused() throws {
        let home = try makePolicyHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let store = DeviceAllowListStore(directory: UserConfigDirectory(home: home))
        try store.update { $0.list.adding(PolicyFixtures.entry()) }
        let file = home + "/.config/offsider/allowed-devices.json"
        let elsewhere = home + "/elsewhere.json"

        try FileManager.default.moveItem(atPath: file, toPath: elsewhere)
        try FileManager.default.createSymbolicLink(atPath: file, withDestinationPath: elsewhere)
        #expect(throws: PrivateDirectoryError.self) { try store.load() }

        try FileManager.default.removeItem(atPath: file)
        try FileManager.default.copyItem(atPath: elsewhere, toPath: file)
        chmod(file, 0o644)
        #expect(throws: PrivateDirectoryError.self) { try store.load() }

        try FileManager.default.removeItem(atPath: file)
        #expect(mkfifo(file, 0o600) == 0)
        #expect(throws: PrivateDirectoryError.self) { try store.load() }
    }
}

@Suite("User config directory")
struct UserConfigDirectoryTests {
    @Test("the home comes from the password database, whatever HOME says")
    func homeFromPasswd() throws {
        let saved = ProcessInfo.processInfo.environment["HOME"]
        setenv("HOME", "/tmp/not-my-home", 1)
        defer { if let saved { setenv("HOME", saved, 1) } }
        let home = try #require(UserConfigDirectory.home())
        #expect(home != "/tmp/not-my-home")
        #expect(home == FileManager.default.homeDirectory(forUser: NSUserName())?.path)
    }

    @Test("a ~/.config symlink to a folder others can write is refused; one to a private folder is followed once")
    func symlinkedConfig() throws {
        let home = try makePolicyHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let target = home + "/real-config"
        try FileManager.default.createDirectory(atPath: target, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(atPath: home + "/.config", withDestinationPath: target)
        let directory = UserConfigDirectory(home: home)

        chmod(target, 0o777)
        #expect(throws: PrivateDirectoryError.self) { try directory.ensure() }

        chmod(target, 0o755)
        #expect(try directory.ensure() == target + "/offsider")
    }
}

@Suite("Physical device policy")
struct PhysicalDevicePolicyTests {
    static let allowed = DeviceAllowList(entries: [PolicyFixtures.entry(apps: ["com.example.one", "com.example.two"])])

    static func decide(_ managed: ManagedDevicePolicy, list: DeviceAllowList = allowed, problem: String? = nil, sealed: Bool = true) -> DeviceDecision {
        PhysicalDevicePolicy(managed: managed, list: list, listProblem: problem, sealIntact: sealed)
            .decision(platform: .ios, key: PolicyFixtures.phone, now: PolicyFixtures.now)
    }

    @Test("managed policy is a ceiling and the person's list is consent: both must say yes", arguments: [
        (ManagedDevicePolicy.none, nil as DeviceRefusal?),
        (ManagedDevicePolicy(allowPhysicalDevices: true), nil),
        (ManagedDevicePolicy(allowPhysicalDevices: false), .managedOff),
        (ManagedDevicePolicy(allowedDeviceIDs: [PolicyFixtures.phone.lowercased()]), nil),
        (ManagedDevicePolicy(allowedDeviceIDs: ["00008130-0000000000000DEF"]), .managedNotListed),
        (ManagedDevicePolicy(allowPhysicalDevices: true, unreadable: true), .managedUnreadable),
    ])
    func precedence(managed: ManagedDevicePolicy, refusal: DeviceRefusal?) {
        let decision = Self.decide(managed)
        if let refusal {
            #expect(decision == .refused(refusal))
        } else {
            #expect(decision == .allowed(Self.allowed.entries[0]))
        }
    }

    @Test("managed policy wins over an unreadable or tampered list, and the list's own problems refuse next")
    func listRefusals() {
        #expect(Self.decide(ManagedDevicePolicy(allowPhysicalDevices: false), problem: "bad") == .refused(.managedOff))
        #expect(Self.decide(.none, problem: "bad") == .refused(.listUnreadable("bad")))
        #expect(Self.decide(.none, sealed: false) == .refused(.listChanged))
        #expect(Self.decide(.none, list: .empty) == .refused(.notAllowed))
        let lapsed = DeviceAllowList(entries: [PolicyFixtures.entry(expires: PolicyFixtures.added)])
        #expect(Self.decide(.none, list: lapsed) == .refused(.expired(PolicyFixtures.added)))
    }

    @Test("permitted apps are the pinned apps within the managed list; a deny-listed app is never permitted")
    func permittedApps() {
        let entry = Self.allowed.entries[0]
        let open = PhysicalDevicePolicy(managed: .none, list: Self.allowed)
        #expect(open.permittedApps(for: entry) == ["com.example.one", "com.example.two"])
        let ceiling = PhysicalDevicePolicy(managed: ManagedDevicePolicy(allowedBundleIDs: ["com.example.two", "com.example.three"]), list: Self.allowed)
        #expect(ceiling.permittedApps(for: entry) == ["com.example.two"])
        #expect(!ceiling.permits(app: "com.example.one", on: entry))
        let unpinned = PolicyFixtures.entry()
        #expect(open.permittedApps(for: unpinned) == nil)
        #expect(open.permits(app: "com.example.any", on: unpinned))
        #expect(!open.permits(app: "com.apple.mobilesafari", on: unpinned))
    }

    @Test("a forced key of the wrong type refuses every physical device")
    func wrongType() {
        let managed = ManagedDevicePolicy.read(from: FakeManagedPreferences(values: [ManagedDevicePolicy.allowedDeviceIDsKey: .unreadable]))
        #expect(managed.unreadable)
        #expect(Self.decide(managed) == .refused(.managedUnreadable))
    }

    @Test("a value written without a profile is not forced, so it is ignored")
    func unforcedIgnored() {
        let domain = "com.mpalmes.offsider.tests.\(UUID().uuidString)" as CFString
        let key = ManagedDevicePolicy.allowPhysicalDevicesKey as CFString
        CFPreferencesSetAppValue(key, kCFBooleanFalse, domain)
        defer {
            CFPreferencesSetAppValue(key, nil, domain)
            CFPreferencesAppSynchronize(domain)
        }
        let live = LiveManagedPreferences(domain: domain as String)
        #expect(live.forcedValue(forKey: ManagedDevicePolicy.allowPhysicalDevicesKey) == nil)
        #expect(!ManagedDevicePolicy.read(from: live).present)
    }

    @Test("status JSON reports managed policy, the list and the one device asked about")
    func statusJSON() throws {
        let policy = PhysicalDevicePolicy(managed: ManagedDevicePolicy(allowedBundleIDs: ["com.example.one"]), list: Self.allowed)
        let text = policy.statusJSON(now: PolicyFixtures.now, only: (.ios, PolicyFixtures.phone))
        let object = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        #expect(object["version"] as? Int == 1)
        #expect(object["allowed"] as? Bool == true)
        let managed = try #require(object["managed"] as? [String: Any])
        #expect(managed["present"] as? Bool == true)
        #expect(managed["allowPhysicalDevices"] is NSNull)
        #expect(managed["allowedBundleIDs"] as? [String] == ["com.example.one"])
        let devices = try #require(object["devices"] as? [[String: Any]])
        #expect(devices.first?["id"] as? String == PolicyFixtures.phone)
        #expect(devices.first?["active"] as? Bool == true)
    }
}

@Suite("Whole-device pin and app refusals")
struct DeviceAppScopeTests {
    static func file(_ platform: String, apps: String) -> Data {
        let id = platform == "ios" ? PolicyFixtures.phone : PolicyFixtures.serial
        return Data(#"{"version":1,"devices":[{"platform":"\#(platform)","id":"\#(id)","name":"Test","added":"2026-09-21T14:13:20Z","expires":null,"apps":\#(apps)}]}"#.utf8)
    }

    @Test("the whole-device pin parses only on an Android entry, pins no app and permits any app the deny-list allows")
    func wholeDevicePin() throws {
        let entry = try #require(try DeviceAllowList.parse(Self.file("android", apps: #"["*"]"#)).entries.first)
        #expect(entry.allowsWholeDevice)
        #expect(entry.pinnedApps.isEmpty)
        let policy = PhysicalDevicePolicy(managed: .none, list: DeviceAllowList(entries: [entry]))
        #expect(policy.permittedApps(for: entry) == nil)
        #expect(policy.permits(app: "com.example.app", on: entry))
        #expect(!policy.permits(app: "com.android.chrome", on: entry))
        #expect(try DeviceAllowList.parse(DeviceAllowList(entries: [entry]).encoded()).entries == [entry])
        #expect(throws: DeviceAllowListError.self) { try DeviceAllowList.parse(Self.file("ios", apps: #"["*"]"#)) }
        #expect(!DeviceAllowance.isAppID(DeviceAllowance.wholeDevicePin))
    }

    @Test("an app outside the pins names the allow command for an agent; a deny-listed app names why; a pinned app passes")
    func appRefusal() {
        let entry = PolicyFixtures.entry(.android, key: PolicyFixtures.serial, apps: ["com.example.app"])
        let policy = PhysicalDevicePolicy(managed: .none, list: DeviceAllowList(entries: [entry]))
        #expect(policy.appRefusal("com.example.app", on: entry) == nil)
        let other = policy.appRefusal("com.example.bank", on: entry, audience: .agent)
        #expect(other?.contains("com.example.bank is not among the apps allowed on Test iPhone (R58M123ABC)") == true)
        #expect(other?.contains("Ask the user to run `offsider devices add`") == true)
        #expect(policy.appRefusal("com.android.chrome", on: entry) == "com.android.chrome is a browser, which Offsider never signs in to or drives. Nothing was read or sent.")
        let ceiling = PhysicalDevicePolicy(managed: ManagedDevicePolicy(allowedBundleIDs: ["com.example.managed"]), list: DeviceAllowList(entries: [entry]))
        #expect(ceiling.appRefusal("com.example.app", on: entry)?.hasPrefix("Managed policy on this Mac does not list com.example.app") == true)
    }
}
