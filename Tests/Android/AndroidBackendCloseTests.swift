import Foundation
import OffsiderCore
import Testing
@testable import OffsiderAndroid

@Suite("Android backend close")
@MainActor
struct AndroidBackendCloseTests {
    static let device = DeviceID(rawValue: "emulator-5556", platform: .android)

    struct Rig {
        let backend: AndroidBackend
        let emulator: FakeEmulator
    }

    /// emulator-5556 whose discovery file offers only a key folder, so gRPC registers a signing key there.
    static func jwtRig(folder: FakeJWKSFolder) throws -> Rig {
        let server = FakeAdbServer(handler: FakeAdbServer.devices(
            ["emulator-5556"],
            host: { service in service == "host:version" ? FakeAdbServer.okay(payload: "0029") : .hang },
            device: { _, service in
                if service.hasSuffix(AndroidDisplayGeometry.probeScript) { return FakeAdbServer.shell(stdout: AndroidBackendTests.geometryOutput) }
                return FakeAdbServer.shell()
            }
        ))
        let home = try AndroidTestHost.homeWithSDK()
        try AndroidTestHost.write(
            "avd.id=Offsider_E2E_Pixel_9\nport.serial=5556\ngrpc.port=8556\ngrpc.jwks=\(folder.jwks.path)\ngrpc.jwk_active=\(folder.active.path)\n",
            to: "Library/Caches/TemporaryItems/avd/running/pid_50144.ini",
            in: home
        )
        let emulator = FakeEmulator()
        let connector = FakeEmulatorConnector(.success(emulator))
        var host = AndroidTestHost.make(home: home, adb: server, emulator: connector, liveProcesses: [50144])
        host.sleep = { _ in folder.activateKeys() }
        return Rig(backend: AndroidBackend(host: host, log: LogRecorder().log), emulator: emulator)
    }

    @Test("close() closes the command's gRPC client, which removes its signing key")
    func closesGrpcAndRemovesKey() async throws {
        let folder = try FakeJWKSFolder()
        let rig = try Self.jwtRig(folder: folder)
        try await rig.backend.perform(.tapAt(x: 10, y: 20), on: Self.device)
        #expect(folder.keyFiles.count == 1)
        #expect(!rig.emulator.calls.contains(.close))

        await rig.backend.close()

        #expect(rig.emulator.calls.last == .close)
        #expect(folder.keyFiles.isEmpty)
        #expect(!EmulatorKeyRegistry.registered.contains { $0.hasPrefix(folder.jwks.path + "/") })
    }

    @Test("a second close() closes nothing again")
    func secondCloseDoesNothing() async throws {
        let rig = try AndroidGrpcInputTests.rig()
        try await rig.backend.perform(.tapAt(x: 10, y: 20), on: Self.device)

        await rig.backend.close()
        await rig.backend.close()

        #expect(rig.emulator.calls.filter { $0 == .close }.count == 1)
    }

    @Test("close() on a backend that did no work talks to nothing")
    func untouchedBackend() async throws {
        let server = FakeAdbServer { _ in .hang }
        let emulator = FakeEmulator()
        let connector = FakeEmulatorConnector(.success(emulator))
        let host = AndroidTestHost.make(home: try AndroidTestHost.homeWithSDK(), adb: server, emulator: connector)

        await AndroidBackend(host: host, log: LogRecorder().log).close()

        #expect(server.connectionAttempts == 0)
        #expect(connector.connections.isEmpty)
        #expect(emulator.calls.isEmpty)
    }

    final class Snapshot: @unchecked Sendable {
        private let lock = NSLock()
        private var value: [FakeEmulator.Call]?
        var calls: [FakeEmulator.Call]? { lock.withLock { value } }
        func take(_ calls: [FakeEmulator.Call]) { lock.withLock { value = calls } }
    }

    @Test("close() stops the helper, and sees it exit, before it closes the gRPC client")
    func helperBeforeGrpc() async throws {
        let device = FakeHelperDevice()
        let emulator = FakeEmulator()
        let atQuit = Snapshot()
        device.answer = { _, op, _ in
            if op == "quit" { atQuit.take(emulator.calls) }
            return nil
        }
        device.other = { service in
            if service.hasSuffix(AndroidDisplayGeometry.probeScript) { return FakeAdbServer.shell(stdout: AndroidBackendTests.geometryOutput) }
            if service.hasSuffix(AndroidDeviceDirectory.propertiesScript) { return FakeAdbServer.shell(stdout: "Offsider_E2E_Pixel_9\n\n1\n16\n36\n") }
            return FakeAdbServer.shell()
        }
        let home = try AndroidTestHost.homeWithSDK()
        try AndroidTestHost.write(
            "avd.id=Offsider_E2E_Pixel_9\nport.serial=5556\ngrpc.port=8556\ngrpc.token=t\n",
            to: "Library/Caches/TemporaryItems/avd/running/pid_50144.ini",
            in: home
        )
        let host = AndroidTestHost.make(
            home: home, adb: device.server(), emulator: FakeEmulatorConnector(.success(emulator)),
            liveProcesses: [50144], helperDex: FakeHelperDevice.dex
        )
        let backend = AndroidBackend(host: host, log: LogRecorder().log)
        _ = try await backend.helperSession(for: "emulator-5556")
        try await backend.perform(.tapAt(x: 10, y: 20), on: Self.device)

        await backend.close()
        await backend.close()

        #expect(atQuit.calls?.contains(.close) == false)
        #expect(emulator.calls.filter { $0 == .close }.count == 1)
        #expect(device.ops == ["hello", "quit"])
        let timeline = device.timeline
        #expect(try #require(timeline.firstIndex(of: "exit 1 0")) < (try #require(timeline.firstIndex(of: "shell closed 1"))))
    }

    @Test("after close() the backend connects again instead of reusing the closed client")
    func reconnectsAfterClose() async throws {
        let rig = try AndroidGrpcInputTests.rig()
        try await rig.backend.perform(.tapAt(x: 10, y: 20), on: Self.device)
        await rig.backend.close()

        try await rig.backend.perform(.tapAt(x: 10, y: 20), on: Self.device)

        #expect(rig.connector.connections.count == 2)
    }
}
