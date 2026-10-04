import Foundation
import OffsiderCore
import Testing
@testable import OffsiderAndroid

@Suite("Android input over gRPC")
@MainActor
struct AndroidGrpcInputTests {
    static let device = DeviceID(rawValue: "emulator-5556", platform: .android)

    nonisolated static let landscape = """
    Physical size: 1080x2424
    Physical density: 420
      Viewport INTERNAL: displayId=0, uniqueId=local:1, port=Optional(0), orientation=1, logicalFrame=[0, 0, 2424, 1080], isActive=[1]
    """

    nonisolated static let resized = """
    Physical size: 1080x2424
    Override size: 720x1616
    Physical density: 420
      Viewport INTERNAL: displayId=0, uniqueId=local:1, port=Optional(0), orientation=0, logicalFrame=[0, 0, 720, 1616], isActive=[1]
    """

    struct Rig {
        let backend: AndroidBackend
        let server: FakeAdbServer
        let emulator: FakeEmulator
        let connector: FakeEmulatorConnector
        let logs: LogRecorder
        let sleeps: SleepRecorder

        var adbScripts: [String] { AndroidInputSessionTests.scripts(server) }
        func touch(_ x: Int32, _ y: Int32, _ pressure: Int32) -> FakeEmulator.Call { .touch(PanelTouch(x: x, y: y, pressure: pressure)) }
    }

    /// emulator-5556 with a live discovery file (token and gRPC port) and a fake endpoint that answers.
    static func rig(
        geometry: String = AndroidBackendTests.geometryOutput,
        emulator: FakeEmulator = FakeEmulator(),
        environment: [String: String] = [:],
        failingScript: @escaping @Sendable (String) -> Bool = { _ in false },
        uiautomatorDump: String? = nil
    ) throws -> Rig {
        let server = FakeAdbServer(handler: FakeAdbServer.devices(
            ["emulator-5556"],
            host: { service in
                switch service {
                case "host:version": return FakeAdbServer.okay(payload: "0029")
                case "host:devices-l": return FakeAdbServer.okay(payload: "emulator-5556 device transport_id:3\n")
                default: return .hang
                }
            },
            device: { _, service in
                if service.hasSuffix(AndroidDisplayGeometry.probeScript) { return FakeAdbServer.shell(stdout: geometry) }
                if service.hasSuffix(AndroidDeviceDirectory.propertiesScript) { return FakeAdbServer.shell(stdout: "Offsider_E2E_Pixel_9\n\n1\n16\n36\n") }
                if let uiautomatorDump, service.contains("uiautomator dump") { return FakeAdbServer.shell(stdout: uiautomatorDump) }
                if failingScript(String(service.dropFirst("shell,v2,raw:".count))) {
                    return FakeAdbServer.shell(stderr: "Error: injection failed\n", status: 1)
                }
                return FakeAdbServer.shell()
            }
        ))
        let home = try AndroidTestHost.homeWithSDK()
        try AndroidTestHost.write(
            "avd.id=Offsider_E2E_Pixel_9\nport.serial=5556\ngrpc.port=8556\ngrpc.token=t\n",
            to: "Library/Caches/TemporaryItems/avd/running/pid_50144.ini",
            in: home
        )
        let connector = FakeEmulatorConnector(.success(emulator))
        let logs = LogRecorder()
        let sleeps = SleepRecorder()
        let host = AndroidTestHost.make(home: home, environment: environment, adb: server, emulator: connector, liveProcesses: [50144], sleeps: sleeps)
        return Rig(backend: AndroidBackend(host: host, log: logs.log), server: server, emulator: emulator, connector: connector, logs: logs, sleeps: sleeps)
    }

    @Test("a tap is a gRPC finger down and up, and adb sends no input")
    func tap() async throws {
        let rig = try Self.rig()
        try await rig.backend.perform(.tapAt(x: 525, y: 1050), on: Self.device)

        #expect(rig.emulator.calls == [rig.touch(525, 1050, 1), rig.touch(525, 1050, 0)])
        #expect(rig.adbScripts.isEmpty)
    }

    @Test("keys go as USB page-7 codes and buttons as W3C key values")
    func keysAndButtons() async throws {
        let rig = try Self.rig()
        try await rig.backend.perform(.composite([.shortKeyPress(4), .shortButtonPress(.home), .shortKeyPress(40)]), on: Self.device)

        #expect(rig.emulator.calls == [.key(.usb(0x070004, .press)), .key(.w3c("GoHome", .press)), .key(.usb(0x070028, .press))])
    }

    @Test("Android's own buttons go as their W3C key values")
    func androidButtons() async throws {
        let rig = try Self.rig()
        try await rig.backend.perform(.composite([.shortButtonPress(.back), .shortButtonPress(.appSwitch), .shortButtonPress(.volumeUp), .shortButtonPress(.volumeDown)]), on: Self.device)

        #expect(rig.emulator.calls == [.key(.w3c("GoBack", .press)), .key(.w3c("AppSwitch", .press)), .key(.w3c("AudioVolumeUp", .press)), .key(.w3c("AudioVolumeDown", .press))])
    }

    @Test("a held key is a real down, a host-timed pause and an up")
    func heldKey() async throws {
        let rig = try Self.rig()
        try await rig.backend.perform(.composite([.keyboard(direction: .down, keyCode: 225), .delay(0.5), .keyboard(direction: .up, keyCode: 225)]), on: Self.device)

        #expect(rig.emulator.calls == [.key(.usb(0x0700E1, .down)), .key(.usb(0x0700E1, .up))])
        #expect(rig.sleeps.sleeps == [.seconds(0.5)])
    }

    @Test("in landscape, touches follow the portrait panel rule")
    func landscapeTap() async throws {
        let rig = try Self.rig(geometry: Self.landscape)
        try await rig.backend.perform(.tapAt(x: 570, y: 714), on: Self.device)

        #expect(rig.emulator.calls == [rig.touch(365, 570, 1), rig.touch(365, 570, 0)])
    }

    @Test("a swipe is a down, host-timed moves and an up")
    func swipe() async throws {
        let rig = try Self.rig()
        try await rig.backend.perform(.swipe(100, yStart: 1000, xEnd: 100, yEnd: 500, delta: 100, duration: 0.3), on: Self.device)

        #expect(rig.emulator.calls == [rig.touch(100, 1000, 1), rig.touch(100, 750, 1), rig.touch(100, 500, 1), rig.touch(100, 500, 0)])
        #expect(rig.sleeps.sleeps == [.seconds(0.15), .seconds(0.15)])
    }

    @Test("a gesture that fails after its down lifts the finger over gRPC when the session closes")
    func failureLiftsFinger() async throws {
        let failure = AndroidError.grpcDeadlineExceeded(method: "sendTouch", seconds: 2)
        let emulator = FakeEmulator { call in call == .touch(PanelTouch(x: 60, y: 10, pressure: 1)) ? failure : nil }
        let rig = try Self.rig(emulator: emulator)
        let session = try await rig.backend.openInputSession(for: Self.device)
        let drag = InputEvent.composite([.touch(direction: .down, x: 10, y: 10), .touch(direction: .down, x: 60, y: 10), .touch(direction: .up, x: 60, y: 10)])

        let error = await #expect(throws: AndroidError.self) { try await session.perform(drag) }
        #expect(error == failure)
        await session.close()
        #expect(emulator.calls == [rig.touch(10, 10, 1), rig.touch(60, 10, 1), rig.touch(60, 10, 0)])
    }

    @Test("detached touches are one gRPC finger across two calls")
    func detachedTouch() async throws {
        let rig = try Self.rig()
        try await rig.backend.sendDetachedTouch([.down(x: 10, y: 20)], to: Self.device)
        try await rig.backend.sendDetachedTouch([.hold(0.25), .up(x: 10, y: 20)], to: Self.device)

        #expect(rig.emulator.calls == [rig.touch(10, 20, 1), rig.touch(10, 20, 0)])
        #expect(rig.sleeps.sleeps == [.seconds(0.25)])
        #expect(rig.adbScripts.isEmpty)
    }

    @Test("the transport is chosen once per command, however many sessions it opens")
    func chosenOnce() async throws {
        let rig = try Self.rig()
        try await rig.backend.perform(.tapAt(x: 1, y: 1), on: Self.device)
        try await rig.backend.perform(.tapAt(x: 2, y: 2), on: Self.device)
        #expect(rig.connector.connections.count == 1)
    }

    @Test("a resized display keeps input on adb and warns once")
    func resizedDisplay() async throws {
        let rig = try Self.rig(geometry: Self.resized)
        try await rig.backend.perform(.tapAt(x: 525, y: 1050), on: Self.device)
        try await rig.backend.perform(.tapAt(x: 525, y: 1050), on: Self.device)

        #expect(rig.adbScripts == ["input tap 525 1050", "input tap 525 1050"])
        #expect(rig.emulator.calls.isEmpty)
        #expect(rig.logs.warnings == ["The display of emulator-5556 is resized (`wm size` reports an override), so its input goes over adb in this command."])
    }

    @Test("OFFSIDER_ANDROID_TRANSPORT=adb keeps input on adb without connecting")
    func forcedAdb() async throws {
        let rig = try Self.rig(environment: ["OFFSIDER_ANDROID_TRANSPORT": "adb"])
        try await rig.backend.perform(.tapAt(x: 525, y: 1050), on: Self.device)

        #expect(rig.adbScripts == ["input tap 525 1050"])
        #expect(rig.connector.connections.isEmpty)
    }
}
