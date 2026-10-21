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

    /// emulator-5556 with a live discovery file (token and gRPC port) and a fake endpoint that answers; `avdHardware` is its AVD's `hardware-qemu.ini`.
    static func rig(
        geometry: String = AndroidBackendTests.geometryOutput,
        emulator: FakeEmulator = FakeEmulator(),
        environment: [String: String] = [:],
        failingScript: @escaping @Sendable (String) -> Bool = { _ in false },
        uiautomatorDump: String? = nil,
        avdHardware: String? = nil
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
                if service.hasSuffix(AndroidDeviceDirectory.propertiesScript) { return FakeAdbServer.shell(stdout: "Offsider_E2E\n\n1\n16\n36\n") }
                if let uiautomatorDump, service.contains("uiautomator dump") { return FakeAdbServer.shell(stdout: uiautomatorDump) }
                if failingScript(String(service.dropFirst("shell,v2,raw:".count))) {
                    return FakeAdbServer.shell(stderr: "Error: injection failed\n", status: 1)
                }
                return FakeAdbServer.shell()
            }
        ))
        let home = try AndroidTestHost.homeWithSDK()
        var discovery = "avd.id=Offsider_E2E\nport.serial=5556\ngrpc.port=8556\ngrpc.token=t\n"
        if let avdHardware {
            discovery += "avd.dir=\(home.appendingPathComponent(".android/avd/Offsider_E2E.avd").path)\n"
            try AndroidTestHost.write(avdHardware, to: ".android/avd/Offsider_E2E.avd/hardware-qemu.ini", in: home)
        }
        try AndroidTestHost.write(discovery, to: "Library/Caches/TemporaryItems/avd/running/pid_50144.ini", in: home)
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

    @Test("the menu button and key 118 both go as evdev KEY_MENU (139): the emulator drops USB usage 118 and maps ContextMenu to Search")
    func menu() async throws {
        let rig = try Self.rig()
        try await rig.backend.perform(.composite([.shortButtonPress(.menu), .shortKeyPress(118)]), on: Self.device)

        #expect(rig.emulator.calls == [.key(.evdev(139, .press)), .key(.evdev(139, .press))])
        #expect(rig.adbScripts.isEmpty)
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

    @Test("two fingers are one gRPC event down with identifiers 0 and 1, a host-timed 1 s hold reporting both at least every 50 ms, never repeating a report, and one event up at pressure 0")
    func twoFingers() async throws {
        let rig = try Self.rig()
        try await rig.backend.perform(.composite([
            .twoFingerTouch(direction: .down, x1: 100, y1: 1000, x2: 160, y2: 1000), .delay(1),
            .twoFingerTouch(direction: .up, x1: 100, y1: 1000, x2: 160, y2: 1000),
        ]), on: Self.device)

        let calls = rig.emulator.calls
        let down = [PanelTouch(x: 100, y: 1000, pressure: 1, identifier: 0), PanelTouch(x: 160, y: 1000, pressure: 1, identifier: 1)]
        #expect(calls.first == .touches(down))
        #expect(calls.last == .touches(down.map { PanelTouch(x: $0.x, y: $0.y, pressure: 0, identifier: $0.identifier) }))
        let held = calls.dropLast().compactMap { call -> [PanelTouch]? in
            if case .touches(let fingers) = call { return fingers }
            return nil
        }
        #expect(held.count == calls.count - 1)
        #expect(held.allSatisfy { $0.map(\.x) == [100, 160] && $0.allSatisfy { $0.pressure > 0 } })
        #expect(zip(held, held.dropFirst()).allSatisfy { $0 != $1 })
        #expect(held.count == rig.sleeps.sleeps.count)
        #expect(rig.sleeps.sleeps.allSatisfy { $0 <= .milliseconds(50) })
        #expect(abs((rig.sleeps.total - .seconds(1)) / .microseconds(1)) < 1)
        #expect(rig.adbScripts.isEmpty)
    }

    static let panel = AndroidDisplayGeometry(
        naturalWidth: 1080, naturalHeight: 2424, logicalWidth: 1080, logicalHeight: 2424, rotation: 0, densityDpi: 420, hasSizeOverride: false
    )

    @Test("while a finger is down, a sleep that overruns is paid back by the next wait, so overruns never build up over a hold")
    func overrunPaidBack() async throws {
        let emulator = FakeEmulator()
        let clock = SleepRecorder()
        let overrun = Duration.milliseconds(3)
        let driver = GrpcInputDriver(emulator: emulator, geometry: Self.panel, sleep: { clock.sleep($0 + overrun) }, uptime: { clock.total })
        let p = AndroidPoint(x: 100, y: 1000)
        try await driver.run([.touch(.down, p), .pause(0.05), .touch(.move, p), .pause(0.05), .touch(.move, p), .pause(0.05), .touch(.up, p)])

        #expect(clock.total == .seconds(0.05) * 3 + overrun)
    }

    @Test("a pause with no finger down sleeps its full length, however long the call before it took")
    func settlePauseKeepsItsLength() async throws {
        let emulator = FakeEmulator()
        let clock = SleepRecorder()
        let driver = GrpcInputDriver(emulator: emulator, geometry: Self.panel, sleep: { clock.sleep($0) }, uptime: {
            clock.total + .milliseconds(300) * emulator.calls.count
        })
        try await driver.run([.tap(AndroidPoint(x: 100, y: 1000)), .pause(0.3), .tap(AndroidPoint(x: 200, y: 1000))])

        #expect(clock.sleeps == [.seconds(0.3)])
    }

    @Test("a hold that a later step of the same session continues swaps pressure from the first report, so none is dropped")
    func restingAcrossSteps() async throws {
        let rig = try Self.rig()
        let session = try await rig.backend.openInputSession(for: Self.device)
        try await session.perform(.touch(direction: .down, x: 100, y: 1000))
        try await session.perform(.delay(0.12))
        try await session.perform(.touch(direction: .up, x: 100, y: 1000))
        await session.close()

        #expect(rig.emulator.calls == [1, 2, 1, 0].map { .touch(PanelTouch(x: 100, y: 1000, pressure: $0)) })
    }

    @Test("a detached touch held over gRPC reports its resting finger too")
    func detachedHold() async throws {
        let rig = try Self.rig()
        try await rig.backend.sendDetachedTouch([.down(x: 100, y: 1000), .hold(0.12), .up(x: 100, y: 1000)], to: Self.device)

        #expect(rig.emulator.calls == [1, 2, 1, 0].map { .touch(PanelTouch(x: 100, y: 1000, pressure: $0)) })
    }

    @Test("while a finger is down, each gRPC call's time comes out of the next wait, and a stall longer than a pause shifts what follows rather than bunching it")
    func pausesEndOnDeadline() async throws {
        let emulator = FakeEmulator()
        let clock = SleepRecorder()
        let callCost = Duration.milliseconds(5)
        let driver = GrpcInputDriver(emulator: emulator, geometry: Self.panel, sleep: { clock.sleep($0) }, uptime: {
            clock.total + callCost * emulator.calls.count + (emulator.calls.count > 2 ? .milliseconds(300) : .zero)
        })
        let p = AndroidPoint(x: 100, y: 1000)
        try await driver.run([.touch(.down, p), .pause(0.05), .touch(.move, p), .pause(0.05), .touch(.move, p), .pause(0.05), .touch(.move, p), .pause(0.05), .touch(.up, p)])

        let shortened = Duration.seconds(0.05) - callCost
        #expect(clock.sleeps == [shortened, shortened, shortened])
    }

    @Test("a finger held still over gRPC is reported where it rests every 50 ms, its pressure swapping so the emulator never drops a repeat")
    func restingFinger() async throws {
        let rig = try Self.rig()
        try await rig.backend.perform(.composite([
            .touch(direction: .down, x: 100, y: 1000), .delay(0.12), .touch(direction: .up, x: 100, y: 1000),
        ]), on: Self.device)

        #expect(rig.emulator.calls == [1, 2, 1, 0].map { .touch(PanelTouch(x: 100, y: 1000, pressure: $0)) })
        #expect(rig.sleeps.sleeps == [.seconds(0.05), .seconds(0.05), .seconds(0.02)])
    }

    @Test("in landscape, both fingers follow the portrait panel rule")
    func twoFingersLandscape() async throws {
        let rig = try Self.rig(geometry: Self.landscape)
        try await rig.backend.perform(.twoFingerTouch(direction: .down, x1: 570, y1: 714, x2: 630, y2: 714), on: Self.device)

        #expect(rig.emulator.calls.first == .touches([PanelTouch(x: 365, y: 570, pressure: 1, identifier: 0), PanelTouch(x: 365, y: 630, pressure: 1, identifier: 1)]))
    }

    @Test("a two-finger down that fails lifts both fingers, best effort")
    func twoFingersFailureLifts() async throws {
        let failure = AndroidError.grpcDeadlineExceeded(method: "sendTouch", seconds: 2)
        let emulator = FakeEmulator { call in
            if case .touches(let touches) = call, touches.first?.pressure == 1 { return failure }
            return nil
        }
        let rig = try Self.rig(emulator: emulator)
        let error = await #expect(throws: AndroidError.self) {
            try await rig.backend.perform(.twoFingerTouch(direction: .down, x1: 10, y1: 10, x2: 70, y2: 10), on: Self.device)
        }
        #expect(error == failure)
        #expect(emulator.calls.last == .touches([PanelTouch(x: 10, y: 10, pressure: 0, identifier: 0), PanelTouch(x: 70, y: 10, pressure: 0, identifier: 1)]))
    }

    @Test("two fingers left down by a failed hold are lifted when the session closes")
    func twoFingersLiftedOnClose() async throws {
        let rig = try Self.rig()
        let session = try await rig.backend.openInputSession(for: Self.device)
        try await session.perform(.twoFingerTouch(direction: .down, x1: 10, y1: 10, x2: 70, y2: 10))
        await session.close()

        #expect(rig.emulator.calls.last == .touches([PanelTouch(x: 10, y: 10, pressure: 0, identifier: 0), PanelTouch(x: 70, y: 10, pressure: 0, identifier: 1)]))
    }
}
