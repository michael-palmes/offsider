import Darwin
import Foundation
import OffsiderCore
import Testing
@testable import Offsider

@Suite("Tree cache")
@MainActor
struct TreeCacheTests {
    static let device = DeviceID(rawValue: "fake-device", platform: .ios)

    static func screen(buttonY: Double = 600, value: String? = nil) -> UITree {
        FakeUI.tree([FakeUI.node(.button, id: "apply", label: "Apply", value: value, frame: FakeUI.frame(20, buttonY, 350, 44))])
    }

    private static func mode(_ path: String) -> mode_t {
        var info = stat()
        lstat(path, &info)
        return info.st_mode & 0o777
    }

    // MARK: Record

    @Test("a record round-trips through its file form with native attributes left out")
    func roundTrip() throws {
        var tree = Self.screen()
        tree.roots[0].children[0].native = .ios(IOSNativeAttributes(type: "Button", pid: 4242))
        let record = TreeCacheRecord(
            platform: .ios, device: "fake-device", command: "tap", writtenAt: Date(timeIntervalSince1970: 1_800_000_000.123),
            treeReadAt: Date(timeIntervalSince1970: 1_799_999_999.5), lastInputAt: Date(timeIntervalSince1970: 1_800_000_000),
            treeRole: .preAction, bootMarker: "launchd_sim 1.000002", screen: UIScreenInfo(width: 402, height: 874, scale: 3, rotationDegrees: 0),
            appFrame: tree.applicationFrame, hash: TreeDiff.hash(tree), roots: tree.roots
        )

        let text = String(decoding: record.encoded(), as: UTF8.self)
        let decoded = try TreeCacheRecord(data: record.encoded())

        #expect(!text.contains("native") && !text.contains("4242"))
        #expect(decoded.treeRole == .preAction)
        #expect(decoded.lastInputAt == record.lastInputAt)
        #expect(decoded.writtenAt == record.writtenAt)
        #expect(decoded.bootMarker == "launchd_sim 1.000002")
        #expect(decoded.screen?.rotationDegrees == 0)
        #expect(decoded.tree.map(TreeDiff.hash) == record.hash)
        #expect(decoded.tree?.roots[0].children[0].frame == FakeUI.frame(20, 600, 350, 44))
    }

    @Test("a record older than 10 minutes, or dated in the future, reads as absent and is deleted")
    func lifetime() async throws {
        let fixture = try TreeCacheFixture()
        let backend = FakeDeviceBackend(trees: [Self.screen()])
        for (age, usable) in [(599.0, true), (600.0, false), (-1.0, false)] {
            try fixture.write(fixture.settledRecord(Self.screen(), age: age))
            let loaded = try await fixture.run { await TreeCache.load(for: Self.device, backend: backend) }
            #expect((loaded != nil) == usable, "age \(age)")
            #expect(FileManager.default.fileExists(atPath: fixture.path(for: Self.device)) == usable, "age \(age)")
        }
    }

    @Test("a record from another boot is ignored")
    func bootMarker() async throws {
        let fixture = try TreeCacheFixture()
        let backend = FakeDeviceBackend(trees: [Self.screen()])
        backend.bootMarkerValue = "launchd_sim 200.000000"
        try fixture.write(fixture.settledRecord(Self.screen(), marker: "launchd_sim 100.000000"))
        #expect(try await fixture.run { await TreeCache.load(for: Self.device, backend: backend) } == nil)

        try fixture.write(fixture.settledRecord(Self.screen(), marker: "launchd_sim 200.000000"))
        #expect(try await fixture.run { await TreeCache.load(for: Self.device, backend: backend) } != nil)
    }

    @Test("a record from another rotation, display or posture does not match the current read")
    func screenChanges() throws {
        let portrait = UIScreenInfo(width: 402, height: 874, rotationDegrees: 0, display: ScreenDisplay(id: "inner", platformId: "1"), posture: .open)
        var record = TreeCacheRecord(platform: .ios, device: "d", command: "describe-ui", writtenAt: Date(), screen: portrait, appFrame: FakeUI.frame(0, 0, 402, 874))
        let frame = FakeUI.frame(0, 0, 402, 874)

        #expect(record.matches(appFrame: frame, screen: portrait))
        #expect(record.matches(appFrame: FakeUI.frame(0, 0, 402.8, 874)))
        #expect(!record.matches(appFrame: FakeUI.frame(0, 0, 874, 402)))
        var turned = portrait
        turned.rotationDegrees = 90
        #expect(!record.matches(appFrame: frame, screen: turned))
        var cover = portrait
        cover.display = ScreenDisplay(id: "cover", platformId: "2")
        #expect(!record.matches(appFrame: frame, screen: cover))
        var folded = portrait
        folded.posture = .halfOpened
        #expect(!record.matches(appFrame: frame, screen: folded))
        record.screen = nil
        #expect(record.matches(appFrame: frame, screen: folded))
        record.screen = try TreeCacheRecord(data: TreeCacheRecord(
            platform: .ios, device: "d", command: "describe-ui", writtenAt: Date(), screen: UIScreenInfo(width: 402, height: 874, rotation: .portrait)
        ).encoded()).screen
        #expect(record.matches(appFrame: frame, screen: UIScreenInfo(width: 402, height: 874, rotation: .portrait)), "a decoded main display matches an unnamed one")
    }

    // MARK: Files

    @Test("the cache file is 0600 in a 0700 directory and named by a hash, not the device")
    func fileModes() async throws {
        let fixture = try TreeCacheFixture()
        let backend = FakeDeviceBackend(trees: [Self.screen()])
        try await fixture.run {
            _ = try await backend.accessibilityTree(for: Self.device)
            await TreeCache.commit(command: "describe-ui", effect: .read, claimed: [], backends: [backend])
        }
        let path = fixture.path(for: Self.device)

        #expect(Self.mode(fixture.directory) == 0o700)
        #expect(Self.mode(path) == 0o600)
        #expect(!path.contains("fake-device"))
        #expect((path as NSString).lastPathComponent.count == 16 + ".json".count)
    }

    @Test("a symlink in place of the cache file is refused")
    func symlinkRefused() throws {
        let fixture = try TreeCacheFixture()
        let target = (fixture.directory as NSString).appendingPathComponent("elsewhere")
        try Data("{}".utf8).write(to: URL(fileURLWithPath: target))
        symlink(target, (fixture.directory as NSString).appendingPathComponent("link.json"))

        #expect(throws: PrivateDirectoryError.self) {
            _ = try OffsiderPrivateDirectory.readOwnedFile(named: "link.json", in: fixture.directory, maxBytes: 1000)
        }
    }

    @Test("a file readable by group or others, or over the size limit, is refused")
    func unsafeFileRefused() throws {
        let fixture = try TreeCacheFixture()
        try OffsiderPrivateDirectory.writeAtomically(Data("{}".utf8), named: "open.json", in: fixture.directory)
        chmod((fixture.directory as NSString).appendingPathComponent("open.json"), 0o644)
        try OffsiderPrivateDirectory.writeAtomically(Data(count: 2000), named: "big.json", in: fixture.directory)

        #expect(throws: PrivateDirectoryError.self) {
            _ = try OffsiderPrivateDirectory.readOwnedFile(named: "open.json", in: fixture.directory, maxBytes: 1000)
        }
        #expect(throws: PrivateDirectoryError.self) {
            _ = try OffsiderPrivateDirectory.readOwnedFile(named: "big.json", in: fixture.directory, maxBytes: 1000)
        }
        #expect(try OffsiderPrivateDirectory.readOwnedFile(named: "missing.json", in: fixture.directory, maxBytes: 1000) == nil)
    }

    @Test("concurrent writers never leave a half-written file")
    func concurrentWriters() async throws {
        let fixture = try TreeCacheFixture()
        let directory = fixture.directory
        let payloads = (0..<8).map { Data(String(repeating: String($0), count: 50_000).utf8) }
        await withTaskGroup(of: Void.self) { group in
            for payload in payloads {
                group.addTask {
                    for _ in 0..<20 { try? OffsiderPrivateDirectory.writeAtomically(payload, named: "race.json", in: directory) }
                }
            }
        }
        let final = try #require(try OffsiderPrivateDirectory.readOwnedFile(named: "race.json", in: directory, maxBytes: 100_000))
        #expect(payloads.contains(final))
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory) == ["race.json"])
    }

    @Test("a secure field's value never reaches a cache file")
    func secureValueNeverCached() async throws {
        let sentinel = "hunter2-cache-sentinel"
        let json = #"[{"type":"Application","frame":{"x":0,"y":0,"width":402,"height":874},"children":[{"type":"SecureTextField","AXUniqueId":"password-field","AXLabel":"Password","AXValue":"\#(sentinel)","frame":{"x":16,"y":270,"width":361,"height":44}}]}]"#
        let tree = UITree(platform: .ios, device: Self.device.rawValue, roots: try IOSAccessibilityMapping.roots(fromJSON: Data(json.utf8)))
        let fixture = try TreeCacheFixture()
        let backend = FakeDeviceBackend(trees: [tree])
        try await fixture.run {
            _ = try await backend.accessibilityTree(for: Self.device)
            await TreeCache.commit(command: "describe-ui", effect: .read, claimed: [], backends: [backend])
        }

        let bytes = try #require(FileManager.default.contents(atPath: fixture.path(for: Self.device)))
        #expect(String(decoding: bytes, as: UTF8.self).contains("password-field"))
        #expect(!String(decoding: bytes, as: UTF8.self).contains(sentinel))
    }

    // MARK: Commit

    private func commit(
        _ fixture: TreeCacheFixture, command: String, effect: CommandEffect, claimed: Set<DeviceLockKey> = [],
        steps: (DeviceActivityLedger) async throws -> Void
    ) async throws -> TreeCacheRecord? {
        try await fixture.run {
            try await steps(DeviceActivityLedger.current)
            await TreeCache.commit(command: command, effect: effect, claimed: claimed, backends: [])
        }
        return try fixture.record(for: Self.device)
    }

    @Test("an input command with a read after its input writes that tree as post-action")
    func postAction() async throws {
        let fixture = try TreeCacheFixture()
        let record = try await commit(fixture, command: "tap", effect: .input) { ledger in
            ledger.recordTreeRead(Self.screen(value: "0"), on: Self.device, startedAt: fixture.now)
            fixture.now += 0.3
            ledger.recordInput(on: Self.device)
            fixture.now += 0.3
            ledger.recordTreeRead(Self.screen(value: "1"), on: Self.device, startedAt: fixture.now)
        }
        #expect(record?.treeRole == .postAction)
        #expect(record?.tree?.roots[0].children[0].value == "1")
        #expect(record?.lastInputAt == fixture.now - 0.3)
    }

    @Test("an input command with only an earlier read keeps that tree as pre-action")
    func preAction() async throws {
        let fixture = try TreeCacheFixture()
        let record = try await commit(fixture, command: "tap", effect: .input) { ledger in
            ledger.recordTreeRead(Self.screen(), on: Self.device, startedAt: fixture.now)
            fixture.now += 0.2
            ledger.recordInput(on: Self.device)
        }
        #expect(record?.treeRole == .preAction)
        #expect(record?.roots != nil)
        #expect(record?.command == "tap")
    }

    @Test("an input command with no read writes a tombstone with the input time")
    func tombstone() async throws {
        let fixture = try TreeCacheFixture()
        let record = try await commit(fixture, command: "swipe", effect: .input) { ledger in
            ledger.recordInput(on: Self.device)
        }
        #expect(record?.roots == nil)
        #expect(record?.treeRole == nil)
        #expect(record?.lastInputAt == fixture.now)
    }

    @Test("a claimed device with no recorded input counts as input when the command ends")
    func safetyNet() async throws {
        let fixture = try TreeCacheFixture()
        let record = try await commit(fixture, command: "orientation", effect: .input, claimed: [DeviceLockKey(platform: .ios, id: Self.device.rawValue)]) { _ in }
        #expect(record?.lastInputAt == fixture.now)
        #expect(record?.roots == nil)
    }

    @Test("a read-only command keeps the last input time and replaces the tree")
    func readKeepsInputTime() async throws {
        let fixture = try TreeCacheFixture()
        let inputAt = fixture.now - 2
        try fixture.write(TreeCacheRecord(platform: .ios, device: Self.device.rawValue, command: "tap", writtenAt: inputAt, lastInputAt: inputAt))
        let record = try await commit(fixture, command: "describe-ui", effect: .read) { ledger in
            ledger.recordTreeRead(Self.screen(), on: Self.device, startedAt: fixture.now)
        }
        #expect(record?.treeRole == .read)
        #expect(record?.lastInputAt == inputAt)
        #expect(record?.command == "describe-ui")
    }

    @Test("a read that began before another command's input does not replace its record")
    func slowReadLoses() async throws {
        let fixture = try TreeCacheFixture()
        let readStart = fixture.now - 1
        try fixture.write(TreeCacheRecord(platform: .ios, device: Self.device.rawValue, command: "tap", writtenAt: fixture.now - 0.5, lastInputAt: fixture.now - 0.5))
        let record = try await commit(fixture, command: "describe-ui", effect: .read) { ledger in
            ledger.recordTreeRead(Self.screen(), on: Self.device, startedAt: readStart)
        }
        #expect(record?.command == "tap")
        #expect(record?.roots == nil)
    }

    @Test("a failed input command still records its input")
    func failedInputRecorded() async throws {
        let fixture = try TreeCacheFixture()
        let tracked = TrackedInputSession.wrapping(RecordingInputSession(failingOn: .tapAt(x: 1, y: 1)))
        _ = try await commit(fixture, command: "tap", effect: .read) { _ in
            await #expect(throws: (any Error).self) { try await tracked.perform(.tapAt(x: 1, y: 1)) }
        }
        #expect(try fixture.record(for: tracked.device)?.lastInputAt == fixture.now)
    }

    @Test("a failed input command that sent nothing is not recorded as input")
    func failedWithoutDispatch() async throws {
        let fixture = try TreeCacheFixture()
        let root = try makePrivateLockRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let claims = DeviceClaims()
        claims.root = { root }
        claims.environment = [:]
        let scope = CommandScope(claims: claims)
        scope.configure(command: "tap")
        try await fixture.run {
            try await DispatchTracker.$current.withValue(DispatchTracker()) {
                await #expect(throws: CLIError.self) {
                    try await scope.run {
                        try await claims.claim(DeviceLockKey(platform: .ios, id: Self.device.rawValue))
                        DeviceActivityLedger.current.recordTreeRead(Self.screen(), on: Self.device, startedAt: fixture.now)
                        throw CLIError(errorDescription: "No accessibility element matched --id 'missing'.", reason: .selectorNotFound)
                    }
                }
            }
        }
        let record = try fixture.record(for: Self.device)
        #expect(record?.lastInputAt == nil)
        #expect(record?.treeRole == .read)
    }

    @Test("a tree over 1 MB is written as a tombstone that keeps the last input time")
    func sizeCap() async throws {
        let fixture = try TreeCacheFixture()
        let rows = (0..<6000).map { FakeUI.node(.text, id: "row-\($0)", label: String(repeating: "x", count: 120), frame: FakeUI.frame(0, Double($0) * 44, 402, 44)) }
        let record = try await commit(fixture, command: "tap", effect: .input) { ledger in
            ledger.recordTreeRead(FakeUI.tree(rows), on: Self.device, startedAt: fixture.now)
            ledger.recordInput(on: Self.device)
        }
        #expect(record?.roots == nil)
        #expect(record?.lastInputAt == fixture.now)
        #expect(try #require(FileManager.default.contents(atPath: fixture.path(for: Self.device))).count < 1000)
    }

    @Test("OFFSIDER_TREE_CACHE=off turns the cache off")
    func switchedOff() {
        #expect(!TreeCacheEnvironment.isEnabled(["OFFSIDER_TREE_CACHE": "off"]))
        #expect(!TreeCacheEnvironment.isEnabled(["OFFSIDER_TREE_CACHE": "OFF"]))
        #expect(TreeCacheEnvironment.isEnabled([:]))
    }
}
