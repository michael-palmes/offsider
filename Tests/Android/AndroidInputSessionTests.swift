import Foundation
import OffsiderCore
import Testing
@testable import OffsiderAndroid

@Suite("Android input session")
@MainActor
struct AndroidInputSessionTests {
    /// Answers the display probe and records every other shell script; `failing` scripts exit 1.
    static func server(failing: @escaping @Sendable (String) -> Bool = { _ in false }) -> FakeAdbServer {
        FakeAdbServer(handler: FakeAdbServer.devices(
            ["emulator-5556"],
            host: { service in
                switch service {
                case "host:version": return FakeAdbServer.okay(payload: "0029")
                case "host:devices-l": return FakeAdbServer.okay(payload: "emulator-5556 device transport_id:3\n")
                default: return .hang
                }
            },
            device: { _, service in
                if service.hasSuffix(AndroidDisplayGeometry.probeScript) {
                    return FakeAdbServer.shell(stdout: AndroidBackendTests.geometryOutput)
                }
                if service.hasSuffix(AndroidDeviceDirectory.propertiesScript) {
                    return FakeAdbServer.shell(stdout: "Offsider_E2E_Pixel_9\n\n1\n16\n36\n")
                }
                let script = String(service.dropFirst("shell,v2,raw:".count))
                return failing(script) ? FakeAdbServer.shell(stderr: "Error: injection failed\n", status: 1) : FakeAdbServer.shell()
            }
        ))
    }

    nonisolated static func scripts(_ server: FakeAdbServer) -> [String] {
        server.services
            .filter { $0.hasPrefix("shell,v2,raw:") && !$0.hasSuffix(AndroidDisplayGeometry.probeScript) && !$0.hasSuffix(AndroidDeviceDirectory.propertiesScript) }
            .map { String($0.dropFirst("shell,v2,raw:".count)) }
    }

    static let device = DeviceID(rawValue: "emulator-5556", platform: .android)

    @Test("one composite is one shell script")
    func compositeIsOneScript() async throws {
        let server = Self.server()
        let session = try await AndroidBackendTests.backend(server).openInputSession(for: Self.device)
        try await session.perform(.composite([.tapAt(x: 525, y: 1050), .delay(0.5), .shortKeyPress(40)]))
        await session.close()

        #expect(Self.scripts(server) == ["input tap 525 1050 && sleep 0.5 && input keyevent 66"])
    }

    @Test("a physical tap is a timed down and up")
    func physicalTap() async throws {
        let server = Self.server()
        let session = try await AndroidBackendTests.backend(server).openInputSession(for: Self.device)
        try await session.performPhysicalTap(at: (x: 100, y: 200), preDelay: nil, postDelay: nil)
        await session.close()

        #expect(Self.scripts(server) == ["input motionevent DOWN 100 200", "input motionevent UP 100 200"])
    }

    @Test("a gesture that fails after its down lifts the finger when the session closes")
    func failureLiftsFinger() async throws {
        let server = Self.server { $0.contains("MOVE") }
        let session = try await AndroidBackendTests.backend(server).openInputSession(for: Self.device)
        let drag = InputEvent.composite([.touch(direction: .down, x: 10, y: 10), .touch(direction: .down, x: 60, y: 10), .touch(direction: .up, x: 60, y: 10)])

        let error = await #expect(throws: AndroidError.self) { try await session.perform(drag) }
        #expect(error?.message == "Input on emulator-5556 failed: Error: injection failed. Check that the emulator is still running with `offsider list-devices`.")
        await session.close()

        #expect(Self.scripts(server).last == "input motionevent UP 60 10")
    }

    @Test("a clean session sends nothing on close")
    func cleanClose() async throws {
        let server = Self.server()
        let session = try await AndroidBackendTests.backend(server).openInputSession(for: Self.device)
        try await session.perform(.tapAt(x: 1, y: 1))
        await session.close()
        #expect(Self.scripts(server) == ["input tap 1 1"])
    }

    @Test("ASCII text goes as input text and key events in one script")
    func typeASCII() async throws {
        let server = Self.server()
        let session = try #require(try await AndroidBackendTests.backend(server).openInputSession(for: Self.device) as? any TextInputSession)
        try await session.typeText("hello world\n")

        #expect(Self.scripts(server) == ["input text 'hello%sworld' && input keyevent 66"])
    }

    @Test("non-ASCII text on an adb-only emulator fails with the gRPC message naming the AVD, and types nothing")
    func typeNonASCII() async throws {
        let server = Self.server()
        let session = try #require(try await AndroidBackendTests.backend(server).openInputSession(for: Self.device) as? any TextInputSession)

        let error = await #expect(throws: AndroidError.self) { try await session.typeText("héllo") }
        #expect(error?.kind == .grpcRequired)
        #expect(error?.message == "Typing non-ASCII text on Android needs the emulator's gRPC endpoint, and emulator-5556 has none (it was probably started with -port). Restart it with `offsider boot Offsider_E2E_Pixel_9`, or type ASCII only.")
        #expect(Self.scripts(server).isEmpty)
    }

    @Test("detached touches become motion events, one script per call")
    func detachedTouch() async throws {
        let server = Self.server()
        let backend = try AndroidBackendTests.backend(server)
        try await backend.sendDetachedTouch([.down(x: 10, y: 20)], to: Self.device)
        try await backend.sendDetachedTouch([.hold(0.25), .up(x: 10, y: 20)], to: Self.device)

        #expect(Self.scripts(server) == ["input motionevent DOWN 10 20", "sleep 0.25 && input motionevent UP 10 20"])
    }
}
