import Foundation
import OffsiderCore
import Testing
@testable import OffsiderAndroid

/// A phone's reverse list as adbd keeps it, answering list, forward and killforward with the bytes the E2E emulator sent.
final class FakeReverses: @unchecked Sendable {
    private let lock = NSLock()
    private var mappings: [(phone: String, mac: String)]
    private var refusesRemoval = false

    init(_ mappings: [(phone: String, mac: String)] = [], refusingRemoval: Bool = false) {
        self.mappings = mappings
        refusesRemoval = refusingRemoval
    }

    var listed: [String] { lock.withLock { mappings.map { "\($0.phone) \($0.mac)" } } }

    func reply(_ service: String) -> FakeAdbServer.Reply? {
        lock.withLock {
            if service == "reverse:list-forward" {
                return FakeAdbServer.okay(payload: mappings.map { "host-27 \($0.phone) \($0.mac)\n" }.joined())
            }
            if service.hasPrefix("reverse:forward:norebind:") {
                let sides = service.dropFirst("reverse:forward:norebind:".count).split(separator: ";").map(String.init)
                guard !mappings.contains(where: { $0.phone == sides[0] }) else { return Self.failed("cannot rebind existing socket") }
                mappings.append((sides[0], sides[1]))
                let port = String(sides[0].dropFirst(4))
                return .bytes(Data("OKAYOKAY".utf8) + Data(String(format: "%04x", port.utf8.count).utf8) + Data(port.utf8), thenClose: true)
            }
            if service.hasPrefix("reverse:killforward:") {
                let phone = String(service.dropFirst("reverse:killforward:".count))
                guard !refusesRemoval, mappings.contains(where: { $0.phone == phone }) else { return Self.failed("listener '\(phone)' not found") }
                mappings.removeAll { $0.phone == phone }
                return .bytes(Data("OKAYOKAY".utf8), thenClose: true)
            }
            return nil
        }
    }

    private static func failed(_ message: String) -> FakeAdbServer.Reply {
        .bytes(Data("OKAYFAIL".utf8) + Data(String(format: "%04x", message.utf8.count).utf8) + Data(message.utf8), thenClose: true)
    }
}

@Suite("Metro adb reverse on a USB phone")
@MainActor
struct AndroidMetroReverseTests {
    static let serial = "R58M123ABC"
    static let phone = DeviceID(rawValue: serial, platform: .android)

    static func server(_ reverses: FakeReverses, transportId: String = "2", serverRunning: Bool = true) -> FakeAdbServer {
        FakeAdbServer(
            connect: serverRunning ? .accept : .refuse,
            handler: FakeAdbServer.devices(
                [serial, "emulator-5556"],
                host: { service in
                    switch service {
                    case "host:version": return FakeAdbServer.okay(payload: "0029")
                    case "host:devices-l": return FakeAdbServer.okay(payload: "\(serial) device usb:1-1 model:Pixel_9 transport_id:\(transportId)\nemulator-5556 device transport_id:9\n")
                    default: return .hang
                    }
                },
                device: { _, service in reverses.reply(service) ?? FakeAdbServer.shell() }
            )
        )
    }

    static func privateDirectory() throws -> String {
        let path = NSTemporaryDirectory() + "offsider-reverses-\(UUID().uuidString)"
        try OffsiderPrivateDirectory.ensurePrivateDirectory(path, uid: getuid())
        return path
    }

    static func host(_ server: FakeAdbServer, directory: String?, environment: [String: String] = [:]) throws -> AndroidHost {
        var host = AndroidTestHost.make(home: try AndroidTestHost.homeWithSDK(), environment: environment, adb: server)
        host.metroReverseDirectory = { directory }
        return host
    }

    static func reverseRequests(_ server: FakeAdbServer) -> [String] {
        server.services.filter { $0.hasPrefix("reverse:forward") || $0.hasPrefix("reverse:killforward") }
    }

    @Test("an allowed port is recorded with the phone's connection, then set as tcp:N tcp:N with norebind")
    func addsAndRecords() async throws {
        let directory = try Self.privateDirectory()
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let reverses = FakeReverses()
        let server = Self.server(reverses)
        let backend = AndroidBackend(host: try Self.host(server, directory: directory)) { _, _ in }

        try await backend.addMetroReverse(port: 8081, on: Self.phone)

        #expect(Self.reverseRequests(server) == ["reverse:forward:norebind:tcp:8081;tcp:8081"])
        #expect(reverses.listed == ["tcp:8081 tcp:8081"])
        #expect(MetroReverseStore(directory: directory).load(serial: Self.serial) == MetroReverseRecord(serial: Self.serial, transportId: "2", ports: [8081]))
        #expect(try await backend.metroHost(port: 8081, on: Self.phone) == ExpoDevClient.loopback)
    }

    @Test("a reverse adb refuses leaves no record behind, so session stop never takes off one Offsider did not set")
    func refusedAddLeavesNoRecord() async throws {
        let directory = try Self.privateDirectory()
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let reverses = FakeReverses([("tcp:8081", "tcp:9000")])
        let backend = AndroidBackend(host: try Self.host(Self.server(reverses), directory: directory)) { _, _ in }

        let error = await #expect(throws: AndroidError.self) { try await backend.addMetroReverse(port: 8081, on: Self.phone) }

        #expect(error?.message.contains("cannot rebind existing socket") == true)
        #expect(reverses.listed == ["tcp:8081 tcp:9000"])
        #expect(MetroReverseStore(directory: directory).load(serial: Self.serial) == nil)
    }

    @Test("an emulator, adb's own port or no private folder sets nothing", arguments: [
        ("emulator-5556", 8081, [:], true),
        (serial, 9123, ["ANDROID_ADB_SERVER_PORT": "9123"], true),
        (serial, 5037, [:], true),
        (serial, 8081, [:], false),
    ] as [(String, Int, [String: String], Bool)])
    func refusals(device: String, port: Int, environment: [String: String], hasDirectory: Bool) async throws {
        let directory = try Self.privateDirectory()
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let server = Self.server(FakeReverses())
        let backend = AndroidBackend(host: try Self.host(server, directory: hasDirectory ? directory : nil, environment: environment)) { _, _ in }

        await #expect(throws: ExpoDevClientError.self) { try await backend.addMetroReverse(port: port, on: DeviceID(rawValue: device, platform: .android)) }

        #expect(Self.reverseRequests(server).isEmpty)
        #expect(MetroReverseStore(directory: directory).all().isEmpty)
    }

    @Test("session stop takes off only the reverses Offsider recorded, leaving a rebound port and the person's own alone")
    func removesOnlyItsOwn() async throws {
        let directory = try Self.privateDirectory()
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let store = MetroReverseStore(directory: directory)
        try store.save(MetroReverseRecord(serial: Self.serial, transportId: "2", ports: [8081, 8742]))
        let reverses = FakeReverses([("tcp:8081", "tcp:8081"), ("tcp:8742", "tcp:9000"), ("tcp:9999", "tcp:9999")])
        let server = Self.server(reverses)

        let removed = await AndroidBackend.removeMetroReverses(host: try Self.host(server, directory: directory), serial: Self.serial)

        #expect(removed == [MetroReverseRemoval(serial: Self.serial, ports: [8081])])
        #expect(Self.reverseRequests(server) == ["reverse:killforward:tcp:8081"])
        #expect(reverses.listed == ["tcp:8742 tcp:9000", "tcp:9999 tcp:9999"])
        #expect(store.load(serial: Self.serial) == nil)
    }

    @Test("a phone reconnected since, or no adb server, lost its reverses already: the record goes and nothing is sent", arguments: [true, false])
    func staleConnection(serverRunning: Bool) async throws {
        let directory = try Self.privateDirectory()
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let store = MetroReverseStore(directory: directory)
        try store.save(MetroReverseRecord(serial: Self.serial, transportId: "1", ports: [8081]))
        let reverses = FakeReverses([("tcp:8081", "tcp:8081")])
        let server = Self.server(reverses, transportId: "2", serverRunning: serverRunning)

        let removed = await AndroidBackend.removeMetroReverses(host: try Self.host(server, directory: directory))

        #expect(removed.isEmpty)
        #expect(reverses.listed == ["tcp:8081 tcp:8081"])
        #expect(Self.reverseRequests(server).isEmpty)
        #expect(store.load(serial: Self.serial) == nil)
    }

    @Test("a removal adb refuses keeps the port recorded, so the next session stop tries again")
    func failedRemovalKeepsRecord() async throws {
        let directory = try Self.privateDirectory()
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let store = MetroReverseStore(directory: directory)
        try store.save(MetroReverseRecord(serial: Self.serial, transportId: "2", ports: [8081]))
        let server = Self.server(FakeReverses([("tcp:8081", "tcp:8081")], refusingRemoval: true))

        let removed = await AndroidBackend.removeMetroReverses(host: try Self.host(server, directory: directory), serial: Self.serial)

        #expect(removed.isEmpty)
        #expect(store.load(serial: Self.serial)?.ports == [8081])
    }

    @Test("with nothing recorded, session stop never reaches adb")
    func nothingRecorded() async throws {
        let directory = try Self.privateDirectory()
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let server = Self.server(FakeReverses([("tcp:8081", "tcp:8081")]))

        #expect(await AndroidBackend.removeMetroReverses(host: try Self.host(server, directory: directory)).isEmpty)
        #expect(server.connectionAttempts == 0)
    }
}
