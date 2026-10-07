import Foundation
import OffsiderCore
import Testing
@testable import OffsiderAndroid

/// Two commands on a Galaxy Z Fold3 sharing one display cache, as two `offsider screenshot` runs do.
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
            case "host:devices-l": return FakeAdbServer.okay(payload: "\(serial) device usb:1-1 product:q2qxxx model:SM_F926B device:q2q transport_id:\(phone.transport)\n")
            default: return .hang
            }
        }) { _, service in
            let closed = phone.closed
            let innerPNG = AndroidMultiDisplayCaptureTests.png(1768, 2208)
            let coverPNG = AndroidMultiDisplayCaptureTests.png(840, 2289)
            switch service {
            case "exec:screencap -p": return FakeAdbServer.exec(ScreencapRawTests.warning + (closed ? coverPNG : innerPNG))
            case "exec:screencap -d \(inner) -p": return FakeAdbServer.exec(innerPNG)
            case "exec:screencap -d \(cover) -p": return FakeAdbServer.exec(coverPNG)
            default: break
            }
            switch String(service.dropFirst("shell,v2,raw:".count)) {
            case AndroidDeviceState.readState: return FakeAdbServer.shell(stdout: GalaxyFoldFixtures.state(closed: closed))
            case AndroidDisplayStatus.scriptWithProbe:
                return FakeAdbServer.shell(stdout: FoldableFixtures.withProbe(GalaxyFoldFixtures.status(closed: closed), GalaxyFoldFixtures.geometry(closed: closed)))
            case AndroidDisplayGeometry.probeScript: return FakeAdbServer.shell(stdout: GalaxyFoldFixtures.geometry(closed: closed))
            default: return FakeAdbServer.shell(stderr: "unexpected", status: 1)
            }
        })
    }

    static func cacheDirectory() throws -> String {
        let root = (NSTemporaryDirectory() as NSString).appendingPathComponent("offsider-display-cache-\(UUID().uuidString)")
        return try OffsiderPrivateDirectory.ensureSubdirectory("displays", root: root)
    }

    /// One command: routes by serial, as the CLI does, then captures; returns the PNG and the services it sent.
    static func command(_ server: FakeAdbServer, cache: String?) async throws -> (png: Data, services: [String]) {
        var host = AndroidTestHost.make(home: try AndroidTestHost.homeWithSDK(), adb: server)
        host.displayCacheDirectory = { cache }
        let backend = AndroidBackend(host: host) { _, _ in }
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

    @Test("the first command learns the inner panel from one status shell; the second captures it with -d alongside device_state and nothing else")
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
        #expect(Set(second.services) == ["exec:screencap -d \(Self.inner) -p", "shell,v2,raw:\(AndroidDeviceState.readState)"])
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
        let tampered = Data(#"{"version":1,"serial":"R58M123ABC","transportId":"7","displayId":"1; reboot","role":"inner","states":[],"committed":null,"width":1768,"height":2208}"#.utf8)
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

    @Test("an entry survives encoding, and a serial never reaches its file name")
    func entryRoundTrip() throws {
        let entry = AndroidDisplayCacheEntry(
            serial: Self.serial, transportId: "7", displayId: Self.inner, role: "inner",
            states: [AndroidDeviceState.State(identifier: 3, name: "OPEN")], committed: AndroidDeviceState.State(identifier: 3, name: "OPEN"),
            width: 1768, height: 2208
        )
        #expect(AndroidDisplayCacheEntry(data: entry.encoded()) == entry)
        #expect(!AndroidDisplayCacheEntry.fileName(serial: Self.serial).contains(Self.serial))
        #expect(!AndroidDisplayCacheEntry.isDisplayId("") && !AndroidDisplayCacheEntry.isDisplayId("-1") && AndroidDisplayCacheEntry.isDisplayId("0"))
    }
}
