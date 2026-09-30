import Foundation
import OffsiderCore
import Testing
@testable import OffsiderAndroid

@Suite("Android backend")
@MainActor
struct AndroidBackendTests {
    nonisolated static let geometryOutput = """
    Physical size: 1080x2424
    Physical density: 420
      Viewport INTERNAL: displayId=0, uniqueId=local:1, port=Optional(0), orientation=0, logicalFrame=[0, 0, 1080, 2424], isActive=[1]
    """

    nonisolated static let listing = """
    emulator-5556 device product:sdk_gphone64_arm64 model:sdk_gphone64_arm64 transport_id:3
    emulator-5558 device product:sdk_gphone64_arm64 model:sdk_gphone64_arm64 transport_id:4
    emulator-5560 offline transport_id:5

    """

    static func server(bootCompleted: String = "1") -> FakeAdbServer {
        FakeAdbServer(handler: FakeAdbServer.devices(
            ["emulator-5556", "emulator-5558"],
            host: { service in
                switch service {
                case "host:version": return FakeAdbServer.okay(payload: "0029")
                case "host:devices-l": return FakeAdbServer.okay(payload: listing)
                default: return .hang
                }
            },
            device: { serial, service in
                if service.hasSuffix(AndroidDisplayGeometry.probeScript) {
                    return FakeAdbServer.shell(stdout: geometryOutput)
                }
                let name = serial == "emulator-5556" ? "Offsider_E2E_Pixel_9" : "Other_AVD"
                return FakeAdbServer.shell(stdout: "\(name)\n\n\(bootCompleted)\n16\n36\n")
            }
        ))
    }

    static func backend(_ server: FakeAdbServer, home: URL? = nil) throws -> AndroidBackend {
        AndroidBackend(host: AndroidTestHost.make(home: try home ?? AndroidTestHost.homeWithSDK(), adb: server)) { _, _ in }
    }

    static let device = DeviceID(rawValue: "emulator-5556", platform: .android)

    @Test("a booted emulator is named by its AVD, and only that emulator is queried")
    func bootedDevice() async throws {
        let server = Self.server()
        let booted = try await Self.backend(server).requireBootedDevice(Self.device)

        #expect(booted.name == "Offsider_E2E_Pixel_9")
        #expect(!server.services.contains("host:transport:emulator-5558"))
    }

    @Test("a booting emulator says to wait or use boot")
    func bootingDevice() async throws {
        let error = await #expect(throws: AndroidError.self) {
            try await Self.backend(Self.server(bootCompleted: "")).requireBootedDevice(Self.device)
        }
        #expect(error?.message == "Emulator emulator-5556 (Offsider_E2E_Pixel_9) is still booting. Wait for it, or run `offsider boot Offsider_E2E_Pixel_9`, which waits until it is ready.")
    }

    @Test("offline and missing serials get their own messages")
    func offlineAndMissing() async throws {
        let backend = try Self.backend(Self.server())
        let offline = await #expect(throws: AndroidError.self) {
            try await backend.requireBootedDevice(DeviceID(rawValue: "emulator-5560", platform: .android))
        }
        #expect(offline?.kind == .deviceOffline)

        let missing = await #expect(throws: AndroidError.self) {
            try await backend.requireBootedDevice(DeviceID(rawValue: "emulator-5570", platform: .android))
        }
        #expect(missing?.message == "No emulator with serial emulator-5570 is running. Run `offsider list-devices` to see running emulators.")
    }

    @Test("screen info is the logical size in dp with the density scale and orientation")
    func screenInfo() async throws {
        let info = try await Self.backend(Self.server()).screenInfo(for: Self.device)
        #expect(info == UIScreenInfo(width: 411.43, height: 923.43, scale: 2.625, orientation: .portrait))
    }

    @Test("dp become logical pixels, probing the display once per command")
    func deviceCoordinates() async throws {
        let server = Self.server()
        let backend = try Self.backend(server)
        let first = try await backend.deviceCoordinates(for: [(x: 200, y: 400)], tree: nil, on: Self.device)
        _ = try await backend.deviceCoordinates(for: [(x: 1, y: 1)], tree: nil, on: Self.device)

        #expect(first.map(\.x) == [525])
        #expect(first.map(\.y) == [1050])
        #expect(server.services.filter { $0.hasSuffix(AndroidDisplayGeometry.probeScript) }.count == 1)
    }

    @Test("list-devices rows come from adb and the AVD folder")
    func listDevices() async throws {
        let rows = try await Self.backend(Self.server()).listDevices()
        #expect(rows.map(\.id) == ["emulator-5556", "emulator-5558", "emulator-5560"])
        #expect(rows.map(\.state) == ["Booted", "Booted", "Offline"])
    }

    @Test("without an SDK, prepare is PlatformUnavailable and an AVD name is simply unknown")
    func noSDK() async throws {
        let server = Self.server()
        let backend = try Self.backend(server, home: AndroidTestHost.temporaryHome())

        await #expect(throws: PlatformUnavailable.self) { try await backend.prepare() }
        let error = await #expect(throws: AndroidError.self) { try await backend.runningSerial(forAVDNamed: "Pixel_10") }
        #expect(error?.message == "No device named Pixel_10. Run `offsider list-devices` to find device IDs.")
        #expect(server.connectionAttempts == 0)
    }
}
