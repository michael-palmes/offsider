import Foundation
import Testing
@testable import OffsiderAndroid

@Suite("Emulator transport selection")
struct EmulatorTransportSelectorTests {
    static let running = "Library/Caches/TemporaryItems/avd/running"

    /// A home whose discovery file for emulator-5556 (pid 50144) has the given extra lines.
    static func home(_ lines: [String]) throws -> URL {
        let home = try AndroidTestHost.temporaryHome()
        let contents = (["avd.id=Offsider_E2E", "port.serial=5556"] + lines).joined(separator: "\n")
        try AndroidTestHost.write(contents, to: "\(running)/pid_50144.ini", in: home)
        return home
    }

    static func choose(
        home: URL,
        environment: [String: String] = [:],
        emulator: FakeEmulatorConnector,
        logs: LogRecorder = LogRecorder(),
        live: Set<Int32> = [50144],
        serial: String = "emulator-5556"
    ) async throws -> AndroidTransport {
        let host = AndroidTestHost.make(home: home, environment: environment, emulator: emulator, liveProcesses: live)
        return try await EmulatorTransportSelector(host: host, log: logs.log).choose(for: serial)
    }

    static func reason(_ transport: AndroidTransport) -> AdbReason? {
        if case .adb(let reason) = transport { return reason }
        return nil
    }

    @Test("a phone uses adb and never gets an emulator's client, even beside a discovery file with no console port")
    func phoneUsesAdb() async throws {
        let home = try AndroidTestHost.temporaryHome()
        try AndroidTestHost.write("avd.id=Portless\ngrpc.port=8556\ngrpc.token=t\n", to: "\(Self.running)/pid_50144.ini", in: home)
        let connector = FakeEmulatorConnector(.success(FakeEmulator()))
        let logs = LogRecorder()

        for serial in ["R5CRFAKE03", "R58M123ABC", "emulator5B"] {
            let transport = try await Self.choose(home: home, emulator: connector, logs: logs, serial: serial)
            #expect(Self.reason(transport) == .physicalDevice)
        }
        #expect(connector.connections.isEmpty)
        #expect(logs.warnings.isEmpty)
    }

    @Test("forcing gRPC on a phone fails naming the physical device")
    func forcedGrpcOnPhone() async throws {
        let connector = FakeEmulatorConnector(.success(FakeEmulator()))
        let error = await #expect(throws: AndroidError.self) {
            _ = try await Self.choose(home: AndroidTestHost.temporaryHome(), environment: ["OFFSIDER_ANDROID_TRANSPORT": "grpc"], emulator: connector, serial: "R58M123ABC")
        }
        #expect(error?.message.contains("R58M123ABC is a physical device") == true)
        #expect(connector.connections.isEmpty)
    }

    @Test("OFFSIDER_ANDROID_TRANSPORT=adb uses adb without looking for an endpoint")
    func forcedAdb() async throws {
        let connector = FakeEmulatorConnector(.success(FakeEmulator()))
        let transport = try await Self.choose(home: Self.home(["grpc.port=8556", "grpc.token=t"]), environment: ["OFFSIDER_ANDROID_TRANSPORT": "adb"], emulator: connector)
        #expect(Self.reason(transport) == .forced)
        #expect(connector.connections.isEmpty)
    }

    @Test("no live discovery file, or one without a gRPC port, is adb with no warning")
    func noEndpoint() async throws {
        let logs = LogRecorder()
        let connector = FakeEmulatorConnector(.success(FakeEmulator()))
        let none = try await Self.choose(home: AndroidTestHost.temporaryHome(), emulator: connector, logs: logs)
        let stale = try await Self.choose(home: Self.home(["grpc.port=8556", "grpc.token=t"]), emulator: connector, logs: logs, live: [])
        let noPort = try await Self.choose(home: Self.home(["grpc.token=t"]), emulator: connector, logs: logs)

        #expect(Self.reason(none) == .noDiscoveryFile)
        #expect(Self.reason(stale) == .noDiscoveryFile)
        #expect(Self.reason(noPort) == .noGrpcPort)
        #expect(logs.warnings.isEmpty)
        #expect(connector.connections.isEmpty)
    }

    @Test("a live endpoint that answers is gRPC, with the token as credentials")
    func grpcChosen() async throws {
        let connector = FakeEmulatorConnector(.success(FakeEmulator()))
        let transport = try await Self.choose(home: Self.home(["grpc.port=8556", "grpc.token=t"]), emulator: connector)

        guard case .grpc = transport else {
            Issue.record("expected gRPC, got \(String(describing: Self.reason(transport)))")
            return
        }
        #expect(connector.connections.map(\.issuer) == ["android-studio"])
        #expect(connector.connections.map(\.port) == [8556])
    }

    @Test("a failed probe falls back to adb with one warning")
    func probeFails() async throws {
        let logs = LogRecorder()
        let rejected = AndroidError.grpcUnauthenticated(endpoint: "127.0.0.1:8556", method: "getStatus", avd: "Offsider_E2E")
        let transport = try await Self.choose(home: Self.home(["grpc.port=8556", "grpc.token=t"]), emulator: FakeEmulatorConnector(.failure(rejected)), logs: logs)

        #expect(Self.reason(transport) == .grpcFailed(rejected.message))
        #expect(logs.warnings == [rejected.message + " Using adb for emulator-5556 instead."])
    }

    @Test("a JWT key the emulator never activates falls back to adb and leaves no key behind")
    func keyNotActivated() async throws {
        let folder = try FakeJWKSFolder()
        let logs = LogRecorder()
        let home = try Self.home(["grpc.port=8556", "grpc.jwks=\(folder.jwks.path)", "grpc.jwk_active=\(folder.active.path)"])
        let connector = FakeEmulatorConnector(.success(FakeEmulator()))
        let transport = try await Self.choose(home: home, emulator: connector, logs: logs)

        #expect(Self.reason(transport).map { if case .grpcFailed = $0 { return true } else { return false } } == true)
        #expect(logs.warnings.count == 1)
        #expect(logs.warnings.first?.hasPrefix("The emulator did not accept Offsider's signing key within 3 s") == true)
        #expect(folder.keyFiles.isEmpty)
        #expect(connector.connections.isEmpty)
    }

    @Test("OFFSIDER_ANDROID_TRANSPORT=grpc turns every fallback into an error")
    func forcedGrpc() async throws {
        let environment = ["OFFSIDER_ANDROID_TRANSPORT": "grpc"]
        let rejected = AndroidError.grpcUnavailable(port: 8556)
        let failing = await #expect(throws: AndroidError.self) {
            try await Self.choose(home: Self.home(["grpc.port=8556", "grpc.token=t"]), environment: environment, emulator: FakeEmulatorConnector(.failure(rejected)))
        }
        #expect(failing == rejected)

        let missing = await #expect(throws: AndroidError.self) {
            try await Self.choose(home: AndroidTestHost.temporaryHome(), environment: environment, emulator: .refusing)
        }
        #expect(missing?.message == "OFFSIDER_ANDROID_TRANSPORT is grpc, which needs the emulator's gRPC endpoint, and emulator-5556 has none (it was probably started with -port). Unset it to fall back to adb.")
    }

    @Test("an unknown transport or auth value is an error, not a silent default")
    func invalidSettings() async throws {
        let home = try Self.home(["grpc.port=8556", "grpc.token=t"])
        let transport = await #expect(throws: AndroidError.self) {
            try await Self.choose(home: home, environment: ["OFFSIDER_ANDROID_TRANSPORT": "usb"], emulator: .refusing)
        }
        #expect(transport?.message == "OFFSIDER_ANDROID_TRANSPORT is usb, which Offsider cannot read. Use auto, adb or grpc, or unset it.")
        let auth = await #expect(throws: AndroidError.self) {
            try await Self.choose(home: home, environment: ["OFFSIDER_ANDROID_GRPC_AUTH": "both"], emulator: .refusing)
        }
        #expect(auth?.kind == .invalidSetting)
    }
}
