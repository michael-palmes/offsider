import Foundation
import OffsiderCore
import Testing
@testable import OffsiderAndroid

/// Two commands on a Galaxy Z Fold sharing one display cache, as two `offsider screenshot` runs do.
@Suite("Android display cache")
@MainActor
struct AndroidDisplayCacheTests {
    static let serial = "R58M123ABC"
    static let phone = DeviceID(rawValue: serial, platform: .android)
    static let inner = GalaxyFoldFixtures.innerId
    static let cover = GalaxyFoldFixtures.coverId

    /// The adb connection a command sees: the hinge, and the phone's `transport_id`, which changes when it is plugged in again.
    final class Phone: @unchecked Sendable {
        private let lock = NSLock()
        private var isClosed = false
        private var transportId = 7
        /// `screencap` without `-d` captures the inner panel whatever the hinge, so the cover needs `-d`.
        let picksInner: Bool
        /// False before API 31, where `cmd device_state` does not exist.
        let hasDeviceState: Bool
        init(picksInner: Bool = false, hasDeviceState: Bool = true) {
            self.picksInner = picksInner
            self.hasDeviceState = hasDeviceState
        }
        var closed: Bool {
            get { lock.withLock { isClosed } }
            set { lock.withLock { isClosed = newValue } }
        }
        var transport: Int {
            get { lock.withLock { transportId } }
            set { lock.withLock { transportId = newValue } }
        }
    }

    static func server(_ phone: Phone) -> FakeAdbServer {
        FakeAdbServer(handler: FakeAdbServer.devices([serial], host: { service in
            switch service {
            case "host:version": return FakeAdbServer.okay(payload: "0029")
            case "host:devices-l": return FakeAdbServer.okay(payload: "\(serial) device usb:1-1 product:f0ldxxx model:SM_F000B device:f0ld transport_id:\(phone.transport)\n")
            default: return .hang
            }
        }) { _, service in
            let closed = phone.closed
            let innerPNG = AndroidMultiDisplayCaptureTests.png(1768, 2208)
            let coverPNG = AndroidMultiDisplayCaptureTests.png(840, 2289)
            switch service {
            case "exec:screencap -p": return FakeAdbServer.exec(ScreencapRawTests.warning + (closed && !phone.picksInner ? coverPNG : innerPNG))
            case "exec:screencap -d \(inner) -p": return FakeAdbServer.exec(innerPNG)
            case "exec:screencap -d \(cover) -p": return FakeAdbServer.exec(coverPNG)
            default: break
            }
            let status = phone.hasDeviceState
                ? GalaxyFoldFixtures.status(closed: closed)
                : FoldableFixtures.status("", "", GalaxyFoldFixtures.dumpsys(closed: closed))
            switch String(service.dropFirst("shell,v2,raw:".count)) {
            case AndroidDeviceState.readState where phone.hasDeviceState: return FakeAdbServer.shell(stdout: GalaxyFoldFixtures.state(closed: closed))
            case AndroidDisplayStatus.scriptWithProbe:
                return FakeAdbServer.shell(stdout: FoldableFixtures.withProbe(status, GalaxyFoldFixtures.geometry(closed: closed)))
            case AndroidDisplayGeometry.probeScript: return FakeAdbServer.shell(stdout: GalaxyFoldFixtures.geometry(closed: closed))
            default: return FakeAdbServer.shell(stderr: "unexpected", status: 1)
            }
        })
    }

    static func cacheDirectory() throws -> String {
        let root = (NSTemporaryDirectory() as NSString).appendingPathComponent("offsider-display-cache-\(UUID().uuidString)")
        return try OffsiderPrivateDirectory.ensureSubdirectory("displays", root: root)
    }

    static func backend(_ server: FakeAdbServer, cache: String?) throws -> AndroidBackend {
        var host = AndroidTestHost.make(home: try AndroidTestHost.homeWithSDK(), adb: server)
        host.displayCacheDirectory = { cache }
        return AndroidBackend(host: host) { _, _ in }
    }

    /// One command: routes by serial, as the CLI does, then captures; returns the PNG and the services it sent.
    static func command(_ server: FakeAdbServer, cache: String?) async throws -> (png: Data, services: [String]) {
        let backend = try Self.backend(server, cache: cache)
        let before = server.services.count
        _ = try await backend.resolveAndroidName(serial)
        let png = try await backend.screenshotPNG(for: phone)
        await backend.close()
        let sent = server.services.dropFirst(before).filter { $0.hasPrefix("exec:") || $0.hasPrefix("shell") }
        return (png, Array(sent))
    }

    static func entry(in directory: String) -> AndroidDisplayCacheEntry? {
        AndroidDisplayCache(directory: directory).load(serial: serial)
    }

    @Test("the first command learns the inner panel from one status shell; the second takes a plain capture, which follows the panel, alongside device_state and nothing else")
    func secondCommandUsesCache() async throws {
        let directory = try Self.cacheDirectory()
        let server = Self.server(Phone())

        let first = try await Self.command(server, cache: directory)
        #expect(first.png == AndroidMultiDisplayCaptureTests.png(1768, 2208))
        #expect(first.services == ["exec:screencap -p", "shell,v2,raw:\(AndroidDisplayStatus.scriptWithProbe)"])
        #expect(Self.entry(in: directory)?.displayId == Self.inner)
        #expect(Self.entry(in: directory)?.role == "inner")

        let second = try await Self.command(server, cache: directory)
        #expect(second.png == AndroidMultiDisplayCaptureTests.png(1768, 2208))
        #expect(Set(second.services) == ["exec:screencap -p", "shell,v2,raw:\(AndroidDeviceState.readState)"])
        #expect(server.services.filter { $0 == "host:devices-l" }.count == 2)
    }

    @Test("folded between commands, the cached panel's device state no longer matches, so the entry is dropped and the cover learnt")
    func foldInvalidates() async throws {
        let directory = try Self.cacheDirectory()
        let phone = Phone()
        let server = Self.server(phone)
        _ = try await Self.command(server, cache: directory)

        phone.closed = true
        let folded = try await Self.command(server, cache: directory)
        #expect(folded.png == AndroidMultiDisplayCaptureTests.png(840, 2289))
        #expect(folded.services.contains("exec:screencap -p"))
        #expect(Self.entry(in: directory)?.displayId == Self.cover)
    }

    static func execs(_ server: FakeAdbServer, after count: Int) -> [String] {
        server.services.dropFirst(count).filter { $0.hasPrefix("exec:") }
    }

    @Test("on a phone whose screencap follows the active panel, a cached command takes plain captures, which follow a fold partway through")
    func cachedCommandFollowsFold() async throws {
        let directory = try Self.cacheDirectory()
        let phone = Phone()
        let server = Self.server(phone)
        _ = try await Self.command(server, cache: directory)
        let backend = try Self.backend(server, cache: directory)
        _ = try await backend.resolveAndroidName(Self.serial)
        let before = server.services.count

        #expect(try await backend.screenshotPNG(for: Self.phone) == AndroidMultiDisplayCaptureTests.png(1768, 2208))
        phone.closed = true
        #expect(try await backend.screenshotPNG(for: Self.phone) == AndroidMultiDisplayCaptureTests.png(840, 2289))
        await backend.close()

        #expect(Self.execs(server, after: before) == ["exec:screencap -p", "exec:screencap -p"])
    }

    @Test("a cached command's later capture of the same panel size is trusted without probing the display again")
    func laterCaptureOfCachedPanelNeedsNoProbe() async throws {
        let directory = try Self.cacheDirectory()
        let server = Self.server(Phone())
        _ = try await Self.command(server, cache: directory)
        let backend = try Self.backend(server, cache: directory)
        _ = try await backend.resolveAndroidName(Self.serial)
        _ = try await backend.screenshotPNG(for: Self.phone)
        let before = server.services.count

        #expect(try await backend.screenshotPNG(for: Self.phone) == AndroidMultiDisplayCaptureTests.png(1768, 2208))
        await backend.close()

        #expect(server.services.dropFirst(before).filter { $0.hasPrefix("exec:") || $0.hasPrefix("shell") } == ["exec:screencap -p"])
    }

    /// An entry as an earlier command wrote it, with no committed state as before API 31.
    static func writeEntry(_ directory: String, displayId: String, followsActive: Bool, width: Int, height: Int) throws {
        let entry = AndroidDisplayCacheEntry(
            serial: serial, transportId: "7", displayId: displayId, role: displayId == inner ? "inner" : "cover",
            states: [], committed: nil, followsActive: followsActive, width: width, height: height
        )
        AndroidDisplayCache(directory: directory).save(entry)
        #expect(Self.entry(in: directory) == entry)
    }

    @Test("folded between commands with no device state to read, a phone whose screencap follows the panel captures the cover, not the dark inner panel")
    func foldWithoutDeviceStateFollowsPanel() async throws {
        let directory = try Self.cacheDirectory()
        try Self.writeEntry(directory, displayId: Self.inner, followsActive: true, width: 1768, height: 2208)
        let phone = Phone()
        phone.closed = true

        let folded = try await Self.command(Self.server(phone), cache: directory)

        #expect(folded.png == AndroidMultiDisplayCaptureTests.png(840, 2289))
        #expect(!folded.services.contains("exec:screencap -d \(Self.inner) -p"))
        #expect(Self.entry(in: directory)?.displayId == Self.cover)
    }

    @Test("with no device state to check it against, a panel that needed -d is never captured from the cache, nor cached")
    func namedPanelNeedsDeviceState() async throws {
        let directory = try Self.cacheDirectory()
        try Self.writeEntry(directory, displayId: Self.cover, followsActive: false, width: 840, height: 2289)
        let phone = Phone(picksInner: true, hasDeviceState: false)
        phone.closed = true

        let result = try await Self.command(Self.server(phone), cache: directory)

        #expect(result.png == AndroidMultiDisplayCaptureTests.png(840, 2289))
        #expect(result.services.first == "exec:screencap -p")
        #expect(Self.entry(in: directory) == nil)
    }

    @Test("on a phone whose screencap needed -d, a cached command keeps naming the cached panel")
    func cachedNamedPickStays() async throws {
        let directory = try Self.cacheDirectory()
        let phone = Phone(picksInner: true)
        phone.closed = true
        let server = Self.server(phone)
        _ = try await Self.command(server, cache: directory)
        let backend = try Self.backend(server, cache: directory)
        _ = try await backend.resolveAndroidName(Self.serial)
        let before = server.services.count

        #expect(try await backend.screenshotPNG(for: Self.phone) == AndroidMultiDisplayCaptureTests.png(840, 2289))
        #expect(try await backend.screenshotPNG(for: Self.phone) == AndroidMultiDisplayCaptureTests.png(840, 2289))
        await backend.close()

        #expect(Self.execs(server, after: before) == ["exec:screencap -d \(Self.cover) -p", "exec:screencap -d \(Self.cover) -p"])
    }

    /// The cache file's inode, which every atomic write replaces.
    static func fileNumber(in directory: String) throws -> Int? {
        let path = (directory as NSString).appendingPathComponent(AndroidDisplayCacheEntry.fileName(serial: serial))
        return (try FileManager.default.attributesOfItem(atPath: path)[.systemFileNumber] as? NSNumber)?.intValue
    }

    @Test("captures of the same panel within one command write the cache once, not once a capture")
    func sameEntryWrittenOnce() async throws {
        let directory = try Self.cacheDirectory()
        let backend = try Self.backend(Self.server(Phone()), cache: directory)
        _ = try await backend.resolveAndroidName(Self.serial)

        _ = try await backend.screenshotPNG(for: Self.phone)
        let written = try Self.fileNumber(in: directory)
        _ = try await backend.screenshotPNG(for: Self.phone)
        _ = try await backend.screenshotPNG(for: Self.phone)
        await backend.close()

        #expect(written != nil)
        #expect(try Self.fileNumber(in: directory) == written)
    }

    @Test("plugged in again, the phone's new adb connection is not trusted: the entry is dropped before any -d capture")
    func transportChangeInvalidates() async throws {
        let directory = try Self.cacheDirectory()
        let phone = Phone()
        let server = Self.server(phone)
        _ = try await Self.command(server, cache: directory)

        phone.transport = 8
        let replugged = try await Self.command(server, cache: directory)
        #expect(replugged.services.first == "exec:screencap -p")
        #expect(!replugged.services.contains("exec:screencap -d \(Self.inner) -p"))
        #expect(Self.entry(in: directory)?.transportId == "8")
    }

    @Test("an entry whose display id is not digits is never sent to the shell, and is removed")
    func tamperedEntryIgnored() async throws {
        let directory = try Self.cacheDirectory()
        let tampered = Data(#"{"version":2,"serial":"R58M123ABC","transportId":"7","displayId":"1; reboot","role":"inner","followsActive":true,"states":[],"committed":null,"width":1768,"height":2208}"#.utf8)
        try OffsiderPrivateDirectory.writeAtomically(tampered, named: AndroidDisplayCacheEntry.fileName(serial: Self.serial), in: directory)

        let result = try await Self.command(Self.server(Phone()), cache: directory)
        #expect(!result.services.contains { $0.contains("reboot") })
        #expect(result.services.first == "exec:screencap -p")
        #expect(Self.entry(in: directory)?.displayId == Self.inner)
    }

    @Test("with the cache off, every command learns the panel again")
    func cacheOff() async throws {
        let server = Self.server(Phone())
        _ = try await Self.command(server, cache: nil)
        let second = try await Self.command(server, cache: nil)
        #expect(second.services == ["exec:screencap -p", "shell,v2,raw:\(AndroidDisplayStatus.scriptWithProbe)"])
        #expect(AndroidDisplayCache.isEnabled(["OFFSIDER_DISPLAY_CACHE": "off"]) == false)
        #expect(AndroidDisplayCache.isEnabled([:]))
    }

    @Test("an entry survives encoding, an entry of the older version is dropped, and a serial never reaches its file name")
    func entryRoundTrip() throws {
        let entry = AndroidDisplayCacheEntry(
            serial: Self.serial, transportId: "7", displayId: Self.inner, role: "inner",
            states: [AndroidDeviceState.State(identifier: 3, name: "OPEN")], committed: AndroidDeviceState.State(identifier: 3, name: "OPEN"),
            followsActive: true, width: 1768, height: 2208
        )
        #expect(AndroidDisplayCacheEntry(data: entry.encoded()) == entry)
        let older = #"{"version":1,"serial":"R58M123ABC","transportId":"7","displayId":"1","role":"inner","states":[],"committed":null,"width":1768,"height":2208}"#
        #expect(AndroidDisplayCacheEntry(data: Data(older.utf8)) == nil)
        #expect(!AndroidDisplayCacheEntry.fileName(serial: Self.serial).contains(Self.serial))
        #expect(!AndroidDisplayCacheEntry.isDisplayId("") && !AndroidDisplayCacheEntry.isDisplayId("-1") && AndroidDisplayCacheEntry.isDisplayId("0"))
    }
}
