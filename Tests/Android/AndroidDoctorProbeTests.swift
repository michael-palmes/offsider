import Foundation
import OffsiderCore
import Testing
@testable import OffsiderAndroid

@Suite("Android doctor probe")
@MainActor
struct AndroidDoctorProbeTests {
    nonisolated static let serial = FakeHelperDevice.serial
    nonisolated static let adbVersion = "Android Debug Bridge version 1.0.41\nVersion 37.0.0-14910828\nInstalled as /sdk/platform-tools/adb\n"
    nonisolated static let sentinel = "SENTINEL-TOKEN-0123456789"

    static func processes() -> RecordingProcessRunner {
        RecordingProcessRunner { call in
            ProcessCaptureResult(status: 0, stdout: call.arguments == ["version"] ? adbVersion : "", stderr: "")
        }
    }

    struct Rig {
        let device: FakeHelperDevice
        let server: FakeAdbServer
        let processes: RecordingProcessRunner
        let probe: AndroidDoctorProbe
    }

    /// emulator-5556 booted; `deviceScript` is what the probe's one getprop and settings shell prints.
    static func rig(
        _ device: FakeHelperDevice = FakeHelperDevice(),
        deviceScript: String = "arm64-v8a\n0\nnull\n",
        home: URL? = nil,
        emulator: FakeEmulatorConnector = .refusing,
        dex: HelperDex? = FakeHelperDevice.dex
    ) throws -> Rig {
        device.other = { service in
            if service.hasSuffix(AndroidDeviceDirectory.propertiesScript) { return FakeAdbServer.shell(stdout: "Offsider_E2E_Pixel_9\n\n1\n16\n36\n") }
            if service.hasSuffix(AndroidDoctorProbe.deviceScript) { return FakeAdbServer.shell(stdout: deviceScript) }
            if service == "reverse:list-forward" { return FakeAdbServer.okay(payload: "host-19 tcp:8742 tcp:8742\n") }
            return FakeAdbServer.shell(status: 1)
        }
        let server = device.server { service in
            switch service {
            case "host:mdns:check": return FakeAdbServer.okay(payload: "ERROR: mdns discovery disabled")
            case "host:devices-l": return FakeAdbServer.okay(payload: "\(serial) device product:sdk model:sdk transport_id:3\n")
            default: return .hang
            }
        }
        let processes = processes()
        let host = AndroidTestHost.make(
            home: try home ?? AndroidTestHost.homeWithSDK(), adb: server, emulator: emulator, processes: processes,
            liveProcesses: [50144], helperDex: dex
        )
        return Rig(device: device, server: server, processes: processes, probe: AndroidDoctorProbe(host: host))
    }

    @Test("the probe never starts the adb server")
    func neverStartsServer() async throws {
        let processes = Self.processes()
        let host = AndroidTestHost.make(
            home: try AndroidTestHost.homeWithSDK(), adb: FakeAdbServer(connect: .refuse) { _ in .hang }, processes: processes
        )
        let facts = await AndroidDoctorProbe(host: host).run(deviceID: Self.serial)

        #expect(facts.host.server == .notRunning(endpoint: "127.0.0.1:5037"))
        #expect(facts.device == nil)
        #expect(processes.calls.map(\.arguments) == [["version"]])
    }

    @Test("the adb-server fix runs start-server with ADB_MDNS=0 and nothing else")
    func fixStartsServer() async throws {
        let processes = Self.processes()
        let host = AndroidTestHost.make(
            home: try AndroidTestHost.homeWithSDK(),
            adb: FakeAdbServer(refusingFirst: 2) { $0.service == "host:version" ? FakeAdbServer.okay(payload: "0029") : .hang },
            processes: processes
        )
        let fix = await AndroidDoctorProbe(host: host).startAdbServerIfAbsent()

        #expect(fix.outcome == .applied)
        #expect(processes.calls.map(\.arguments) == [["start-server"]])
        #expect(processes.calls.first?.environment?["ADB_MDNS"] == "0")
    }

    @Test("the adb-server fix leaves a running server alone")
    func fixSkipsRunningServer() async throws {
        let rig = try Self.rig()
        let fix = await rig.probe.startAdbServerIfAbsent()

        #expect(fix.outcome == .skipped)
        #expect(rig.processes.calls.isEmpty)
    }

    @Test("the probe never sends a reverse or forward request, and reads the Metro reverse")
    func readOnlyReverse() async throws {
        let rig = try Self.rig()
        let facts = await rig.probe.run(deviceID: Self.serial)

        #expect(rig.server.services.filter { $0.contains("reverse") || $0.contains("forward") } == ["reverse:list-forward"])
        #expect(facts.device?.reverses == ["host-19 tcp:8742 tcp:8742"])
        #expect(facts.host.mdns == .disabled("ERROR: mdns discovery disabled"))
    }

    @Test("the helper probe reports ready and its launch, hello and ping, then quits")
    func helperReady() async throws {
        let rig = try Self.rig()
        let facts = await rig.probe.run(deviceID: Self.serial)

        guard case .ready(_, let pushed, _, _, let protocolVersion, _)? = facts.device?.helper else {
            Issue.record("expected a ready helper, got \(String(describing: facts.device?.helper))")
            return
        }
        #expect(!pushed)
        #expect(protocolVersion == 1)
        #expect(rig.device.ops == ["hello", "ping", "quit"])
    }

    @Test("the helper probe reports a push when the dex is missing")
    func helperPushed() async throws {
        let rig = try Self.rig(FakeHelperDevice(dexOnDevice: false))
        let facts = await rig.probe.run(deviceID: Self.serial)

        guard case .ready(_, let pushed, _, _, _, _)? = facts.device?.helper else {
            Issue.record("expected a ready helper, got \(String(describing: facts.device?.helper))")
            return
        }
        #expect(pushed)
    }

    @Test("the helper probe is skipped while an Offsider helper is running")
    func helperSkippedWhileRunning() async throws {
        let rig = try Self.rig(deviceScript: "arm64-v8a\n1\nnull\n4321\n")
        let facts = await rig.probe.run(deviceID: Self.serial)

        #expect(facts.device?.uiAutomation?.offsiderHelperPids == [4321])
        #expect(facts.device?.helper == nil)
        #expect(rig.device.startedProcesses == 0)
    }

    @Test("an AVD name that is not running fails the device state without throwing")
    func unknownAVD() async throws {
        let rig = try Self.rig()
        let facts = await rig.probe.run(deviceID: "Nobody_AVD")

        guard case .notFound(let message)? = facts.device?.state else {
            Issue.record("expected notFound, got \(String(describing: facts.device?.state))")
            return
        }
        #expect(message.contains("Nobody_AVD"))
    }

    @Test("the gRPC token never appears in the facts, connected or failed")
    func tokenNeverShown() async throws {
        let home = try AndroidTestHost.homeWithSDK()
        try AndroidTestHost.write(
            "avd.id=Offsider_E2E_Pixel_9\nport.serial=5556\ngrpc.port=8556\ngrpc.token=\(Self.sentinel)\n",
            to: "\(EmulatorTransportSelectorTests.running)/pid_50144.ini",
            in: home
        )
        let connected = try Self.rig(home: home, emulator: FakeEmulatorConnector(.success(FakeEmulator())))
        let failing = try Self.rig(
            home: home,
            emulator: FakeEmulatorConnector(.failure(.grpcFailed(endpoint: "127.0.0.1:8556", method: "getStatus", detail: "rejected Bearer \(Self.sentinel)")))
        )
        let good = await connected.probe.run(deviceID: Self.serial)
        let bad = await failing.probe.run(deviceID: Self.serial)

        guard case .connected(_, let auth, _, _)? = good.device?.grpc else {
            Issue.record("expected a connected endpoint, got \(String(describing: good.device?.grpc))")
            return
        }
        #expect(auth == "token")
        guard case .failed? = bad.device?.grpc else {
            Issue.record("expected a failed endpoint, got \(String(describing: bad.device?.grpc))")
            return
        }
        for facts in [good, bad] {
            let checks = AndroidDoctorRules.deviceChecks(facts.device, hostBlocker: nil)
            let text = String(describing: facts) + checks.map { "\($0.detail) \($0.hint ?? "")" }.joined()
            #expect(!text.contains(Self.sentinel))
        }
    }

    @Test("adb version output gives the release and the protocol")
    func adbVersionParsing() {
        #expect(AndroidDoctorProbe.adbVersion(Self.adbVersion) == .version("37.0.0-14910828", protocolVersion: 41))
        if case .failed = AndroidDoctorProbe.adbVersion("garbage") {} else { Issue.record("expected a failure") }
    }
}
