import Darwin
import Foundation
import OffsiderCore
import Testing
@testable import Offsider
@testable import OffsiderAndroid

@Suite("Sign-in ledger")
struct SignInLedgerTests {
    static let app = "com.example.app"
    static let simulator = "00000000-0000-0000-0000-000000000001"
    static let otherSimulator = "00000000-0000-0000-0000-000000000002"
    static let start = Date(timeIntervalSince1970: 1_760_000_000)

    static func record(
        _ key: String, app: String = app, platform: DevicePlatform = .ios, device: String = simulator,
        at offset: TimeInterval = 0, bootMarker: String? = nil
    ) -> SignInRecord {
        SignInRecord(app: app, foreground: app, key: key, platform: platform, device: device, since: start + offset, bootMarker: bootMarker)
    }

    static func withLedger(_ body: (SignInLedger, String) throws -> Void) throws {
        let root = try makePrivateLockRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try body(SignInLedger(root: root), (root as NSString).appendingPathComponent(OffsiderPrivateDirectory.signInsDirectoryName))
    }

    @Test("a new sign-in replaces the last one for that device and app, and another app keeps its own")
    func replacesPerDeviceAndApp() throws {
        try Self.withLedger { ledger, _ in
            try ledger.record(Self.record("qa-admin"))
            try ledger.record(Self.record("qa-admin", app: "com.example.other"))
            try ledger.record(Self.record("qa-member", at: 60))

            #expect(ledger.record(platform: .ios, device: Self.simulator, app: Self.app)?.key == "qa-member")
            #expect(ledger.record(platform: .ios, device: Self.simulator, app: "com.example.other")?.key == "qa-admin")
            #expect(ledger.record(platform: .ios, device: Self.otherSimulator, app: Self.app) == nil)
        }
    }

    @Test("sign-ins group by saved login across devices, newest first, and leave out other apps")
    func groupsByLogin() throws {
        try Self.withLedger { ledger, _ in
            try ledger.record(Self.record("qa-admin", device: Self.simulator, at: 0))
            try ledger.record(Self.record("qa-admin", platform: .android, device: "Test_AVD", at: 30))
            try ledger.record(Self.record("*", device: Self.otherSimulator, at: 10))
            try ledger.record(Self.record("qa-admin", app: "com.example.other", device: Self.otherSimulator))

            let grouped = ledger.signIns(app: Self.app) { _, _ in nil }

            #expect(grouped == [
                "qa-admin": [
                    LoginSignIn(device: "Test_AVD", platform: .android, since: Self.start + 30, restarted: nil),
                    LoginSignIn(device: Self.simulator, platform: .ios, since: Self.start, restarted: nil),
                ],
                "*": [LoginSignIn(device: Self.otherSimulator, platform: .ios, since: Self.start + 10, restarted: nil)],
            ])
        }
    }

    @Test(
        "restarted is known only when both boot markers are",
        arguments: [
            (nil, nil, nil),
            ("launchd_sim 1.000001", nil, nil),
            (nil, "launchd_sim 1.000001", nil),
            ("launchd_sim 1.000001", "launchd_sim 1.000001", false),
            ("launchd_sim 1.000001", "launchd_sim 9.000001", true),
        ] as [(String?, String?, Bool?)]
    )
    func restarted(recorded: String?, current: String?, expected: Bool?) throws {
        #expect(SignInLedger.restarted(recorded: recorded, current: current) == expected)
        try Self.withLedger { ledger, _ in
            try ledger.record(Self.record("qa-admin", bootMarker: recorded))
            let signIn = ledger.signIns(app: Self.app) { _, _ in current }["qa-admin"]?.first
            #expect(signIn?.restarted == expected)
        }
    }

    @Test("signing out clears one device, and removing a login clears it on every device")
    func clears() throws {
        try Self.withLedger { ledger, _ in
            try ledger.record(Self.record("qa-admin", device: Self.simulator))
            try ledger.record(Self.record("qa-admin", platform: .android, device: "Test_AVD"))
            try ledger.record(Self.record("qa-member", device: Self.otherSimulator))
            try ledger.record(Self.record("qa-admin", app: "com.example.other"))

            #expect(ledger.clear(platform: .ios, device: Self.simulator, app: Self.app)?.key == "qa-admin")
            #expect(ledger.clear(platform: .ios, device: Self.simulator, app: Self.app) == nil)
            #expect(ledger.record(platform: .android, device: "Test_AVD", app: Self.app) != nil)

            let removed = ledger.clear(app: Self.app, key: "qa-admin")

            #expect(removed.map(\.device) == ["Test_AVD"])
            #expect(ledger.signIns(app: Self.app) { _, _ in nil }.keys.sorted() == ["qa-member"])
            #expect(ledger.record(platform: .ios, device: Self.simulator, app: "com.example.other")?.key == "qa-admin")
        }
    }

    @Test("a record file holds only the documented keys under a hashed name, never a username or password")
    func recordContents() throws {
        try Self.withLedger { ledger, directory in
            try ledger.record(Self.record("qa-admin", bootMarker: "launchd_sim 1.000001"))
            try ledger.record(Self.record("qa-member", device: Self.otherSimulator))

            let names = try FileManager.default.contentsOfDirectory(atPath: directory).filter { !$0.hasPrefix(".") }.sorted()
            #expect(names.count == 2)
            #expect(names.allSatisfy { $0.count == 21 && $0.hasSuffix(".json") && $0.prefix(16).allSatisfy(\.isHexDigit) && $0 == $0.lowercased() })
            var keySets: [Set<String>] = []
            for name in names {
                let data = try #require(FileManager.default.contents(atPath: (directory as NSString).appendingPathComponent(name)))
                let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
                #expect(object["v"] as? Int == 1)
                keySets.append(Set(object.keys))
                let attributes = try FileManager.default.attributesOfItem(atPath: (directory as NSString).appendingPathComponent(name))
                #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
            }
            let documented: Set<String> = ["v", "app", "foreground", "key", "platform", "device", "since"]
            #expect(Set(keySets) == [documented, documented.union(["bootMarker"])])
        }
    }

    @Test("a record over 4096 bytes is refused and nothing is written")
    func oversizedRecordRefused() throws {
        try Self.withLedger { ledger, directory in
            #expect(throws: PrivateDirectoryError.self) {
                try ledger.record(Self.record("qa-admin", app: "com.example." + String(repeating: "a", count: 4096)))
            }
            let written = try FileManager.default.contentsOfDirectory(atPath: directory).filter { $0.hasSuffix(".json") }
            #expect(written.isEmpty)
        }
    }

    @Test("symlinked, shared, oversized, misnamed and newer files are ignored")
    func unsafeFilesIgnored() throws {
        try Self.withLedger { ledger, directory in
            try ledger.record(Self.record("qa-member", device: Self.otherSimulator))
            let data = Self.record("qa-admin").encoded()
            let name = SignInLedger.fileName(platform: .ios, device: Self.simulator, app: Self.app)
            let path = (directory as NSString).appendingPathComponent(name)
            let outside = ((directory as NSString).deletingLastPathComponent as NSString).appendingPathComponent("outside.json")
            try data.write(to: URL(fileURLWithPath: outside))
            chmod(outside, 0o600)

            #expect(symlink(outside, path) == 0)
            #expect(ledger.record(platform: .ios, device: Self.simulator, app: Self.app) == nil)

            let newer = Data(String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\"v\":1", with: "\"v\":2").utf8)
            let oversized = data + Data(repeating: 0x20, count: SignInRecord.maximumBytes)
            for (contents, mode, readable) in [(data, 0o600, true), (data, 0o644, false), (oversized, 0o600, false), (newer, 0o600, false)] {
                unlink(path)
                #expect(FileManager.default.createFile(atPath: path, contents: contents, attributes: [.posixPermissions: mode]))
                #expect((ledger.record(platform: .ios, device: Self.simulator, app: Self.app) != nil) == readable)
            }
            unlink(path)
            #expect(FileManager.default.createFile(atPath: (directory as NSString).appendingPathComponent("0123456789abcdef.json"), contents: data, attributes: [.posixPermissions: 0o600]))

            #expect(ledger.signIns(app: Self.app) { _, _ in nil }.keys.sorted() == ["qa-member"])
            #expect(ledger.clear(app: Self.app, key: "qa-admin").isEmpty)
        }
    }

    @Test("reads and clears find nothing and create nothing until a sign-in is recorded")
    func readsCreateNothing() throws {
        try Self.withLedger { ledger, directory in
            #expect(ledger.record(platform: .ios, device: Self.simulator, app: Self.app) == nil)
            #expect(ledger.signIns(app: Self.app) { _, _ in "launchd_sim 1.000001" }.isEmpty)
            #expect(ledger.clear(platform: .ios, device: Self.simulator, app: Self.app) == nil)
            #expect(ledger.clear(app: Self.app, key: "qa-admin").isEmpty)
            #expect(!FileManager.default.fileExists(atPath: directory))

            try ledger.record(Self.record("qa-admin"))
            #expect(ledger.record(platform: .ios, device: Self.simulator, app: Self.app)?.key == "qa-admin")
        }
        let missingRoot = (NSTemporaryDirectory() as NSString).appendingPathComponent("offsider-signins-test-\(UUID().uuidString)")
        #expect(SignInLedger(root: missingRoot).signIns(app: Self.app) { _, _ in nil }.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: missingRoot))
    }

    @Test("a symlinked or shared signins directory is refused on read as it is on write")
    func unsafeDirectoryRefused() throws {
        try Self.withLedger { ledger, directory in
            let elsewhere = try makePrivateLockRoot()
            defer { try? FileManager.default.removeItem(atPath: elsewhere) }
            try SignInLedger(root: elsewhere).record(Self.record("qa-admin"))
            let real = (elsewhere as NSString).appendingPathComponent(OffsiderPrivateDirectory.signInsDirectoryName)

            #expect(symlink(real, directory) == 0)
            #expect(ledger.record(platform: .ios, device: Self.simulator, app: Self.app) == nil)
            #expect(ledger.signIns(app: Self.app) { _, _ in nil }.isEmpty)
            #expect(throws: PrivateDirectoryError.self) { try ledger.record(Self.record("qa-member")) }

            unlink(directory)
            try FileManager.default.copyItem(atPath: real, toPath: directory)
            #expect(ledger.record(platform: .ios, device: Self.simulator, app: Self.app)?.key == "qa-admin")
            chmod(directory, 0o755)
            #expect(ledger.record(platform: .ios, device: Self.simulator, app: Self.app) == nil)
            #expect(ledger.signIns(app: Self.app) { _, _ in nil }.isEmpty)
        }
    }
}


/// A sign-in tracker over a temporary private root and a fake home where emulator-5554 runs Test_AVD.
struct SignInTrackerFixture {
    static let started = Date(timeIntervalSince1970: 1_760_000_000)
    static let discovery = """
    avd.id=Test_AVD
    avd.name=Test_AVD
    port.serial=5554
    port.adb=5555
    grpc.port=8554
    """

    let root: String
    let home: URL
    var tracker: SignInTracker

    init(now: Date = started) throws {
        let root = try makePrivateLockRoot()
        let home = try AndroidTestHost.temporaryHome()
        self.root = root
        self.home = home
        tracker = SignInTracker(ledger: SignInLedger(root: root), host: try Self.host(home: home, startedAt: Self.started), now: { now })
    }

    /// The same ledger once the emulator has restarted.
    func restarted() throws -> SignInTracker {
        SignInTracker(ledger: tracker.ledger, host: try Self.host(home: home, startedAt: Self.started + 500), now: tracker.now)
    }

    func remove() {
        try? FileManager.default.removeItem(atPath: root)
        try? FileManager.default.removeItem(at: home)
    }

    static func host(
        home: URL, startedAt: Date, adb: FakeAdbServer = FakeAdbServer { _ in .hang }, processes: RecordingProcessRunner = RecordingProcessRunner()
    ) throws -> AndroidHost {
        try AndroidTestHost.write(discovery, to: "Library/Caches/TemporaryItems/avd/running/pid_700.ini", in: home)
        return AndroidTestHost.make(home: home, adb: adb, processes: processes, liveProcesses: [700], startTimes: [700: startedAt])
    }
}

@Suite("Sign-in device keys")
struct SignInDeviceTests {
    @Test("an emulator serial and its AVD name share one key and boot marker, read from local files alone")
    func serialAndAVDShareKey() async throws {
        let home = try AndroidTestHost.temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let adb = FakeAdbServer { _ in .hang }
        let processes = RecordingProcessRunner()
        let host = try SignInTrackerFixture.host(home: home, startedAt: Date(timeIntervalSince1970: 1_760_000_000.25), adb: adb, processes: processes)

        let bySerial = try #require(SignInDevice.key(rawID: "emulator-5554", host: host))
        let byName = try #require(SignInDevice.key(rawID: "Test_AVD", host: host))

        #expect(bySerial.platform == .android && bySerial.key == "Test_AVD")
        #expect(byName.platform == bySerial.platform && byName.key == bySerial.key)
        let marker = SignInDevice.bootMarker(platform: .android, key: "Test_AVD", host: host)
        #expect(marker == "emulator 1760000000.250000")
        #expect(await AndroidBackend(host: host) { _, _ in }.bootMarker(for: DeviceID(rawValue: "emulator-5554", platform: .android)) == marker)
        #expect(SignInDevice.key(rawID: "emulator-5556", host: host) == nil)
        #expect(SignInDevice.bootMarker(platform: .android, key: "ZY22FAKE01", host: host) == nil)
        #expect(adb.connectionAttempts == 0)
        #expect(processes.calls.isEmpty)
    }

    @Test("a simulator that is not running, or a physical iPhone, has no boot marker")
    func iosMarkerUnknown() {
        #expect(SignInDevice.bootMarker(platform: .ios, key: "00000000-0000-0000-0000-000000000001") == nil)
        #expect(SignInDevice.bootMarker(platform: .ios, key: "00008130-0000000000000ABC") == nil)
    }

    @Test("a sign-in on an emulator serial is recorded under its AVD, and shows as restarted after the emulator restarts")
    func recordsUnderAVD() throws {
        let fixture = try SignInTrackerFixture()
        defer { fixture.remove() }
        let tracker = fixture.tracker

        let recorded = tracker.record(app: "com.example.app", foreground: "com.example.app", key: "qa-admin", deviceID: "emulator-5554")

        #expect(recorded?.device == "Test_AVD")
        #expect(tracker.signedInHere(app: "com.example.app", deviceID: "Test_AVD") == "qa-admin")
        #expect(tracker.last(app: "com.example.app", deviceID: "emulator-5554")?.restarted == false)
        let restarted = try fixture.restarted()
        #expect(restarted.last(app: "com.example.app", deviceID: "emulator-5554")?.restarted == true)
        #expect(restarted.signIns(app: "com.example.app")["qa-admin"]?.first?.restarted == true)
        #expect(tracker.record(app: "com.example.app", foreground: "com.example.app", key: "qa-admin", deviceID: "emulator-5556") == nil)
    }

    @Test("status reads each running device's start time once, and who is signed in here reads none")
    func bootMarkerReads() throws {
        var fixture = try SignInTrackerFixture()
        defer { fixture.remove() }
        fixture.tracker.record(app: "com.example.app", foreground: "com.example.app", key: "qa-admin", deviceID: "emulator-5554")
        fixture.tracker.record(app: "com.example.app", foreground: "com.example.app", key: "qa-member", deviceID: "ZY22FAKE01")
        let reads = AndroidBackendTreeTests.Counter()
        let startTime = fixture.tracker.host.processStartTime
        fixture.tracker.host.processStartTime = { pid in
            _ = reads.next()
            return startTime(pid)
        }

        #expect(fixture.tracker.signedInHere(app: "com.example.app", deviceID: "emulator-5554") == "qa-admin")
        #expect(reads.count == 0)
        #expect(fixture.tracker.signIns(app: "com.example.app")["qa-admin"]?.first?.restarted == false)
        #expect(reads.count == 1)
    }
}
