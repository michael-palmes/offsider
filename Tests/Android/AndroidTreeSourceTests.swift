import Foundation
import OffsiderCore
import Testing
@testable import OffsiderAndroid

/// A backend on a `FakeHelperDevice` that also answers the display probe and uiautomator, the fallback's two shells.
@MainActor
struct HelperRig {
    let backend: AndroidBackend
    let device: FakeHelperDevice
    let server: FakeAdbServer
    let log: LogRecorder
    let sleeps: SleepRecorder

    static let device = DeviceID(rawValue: "emulator-5556", platform: .android)

    init(
        _ device: FakeHelperDevice = FakeHelperDevice(),
        environment: [String: String] = [:],
        dex: HelperDex? = FakeHelperDevice.dex,
        emulator: FakeEmulatorConnector = .refusing,
        home: URL? = nil
    ) throws {
        device.other = { service in
            if service.hasSuffix(AndroidDisplayGeometry.probeScript) { return FakeAdbServer.shell(stdout: AndroidBackendTests.geometryOutput) }
            if service.hasSuffix(AndroidDeviceDirectory.propertiesScript) { return FakeAdbServer.shell(stdout: "Offsider_E2E\n\n1\n16\n36\n") }
            if service.contains("uiautomator dump") { return FakeAdbServer.shell(stdout: AndroidBackendTreeTests.dump(rotation: 0)) }
            return FakeAdbServer.shell()
        }
        let server = device.server()
        let log = LogRecorder()
        let sleeps = SleepRecorder()
        let host = AndroidTestHost.make(
            home: try home ?? AndroidTestHost.homeWithSDK(), environment: environment, adb: server, emulator: emulator,
            liveProcesses: [50144], sleeps: sleeps, helperDex: dex
        )
        backend = AndroidBackend(host: host, log: log.log)
        self.device = device
        self.server = server
        self.log = log
        self.sleeps = sleeps
    }

    var startShells: Int { server.services.filter { $0.contains("app_process") }.count }
    var uiautomatorDumps: Int { server.services.filter { $0.contains("uiautomator dump") }.count }

    func read() async throws -> UITree {
        try await backend.accessibilityTree(for: Self.device, point: nil)
    }
}

@Suite("Android tree source")
@MainActor
struct AndroidTreeSourceTests {
    static func mode(_ value: String?) throws -> AndroidTreeMode {
        try AndroidTreeMode.mode(host: AndroidTestHost.make(environment: value.map { ["OFFSIDER_ANDROID_TREE": $0] } ?? [:]))
    }

    @Test("OFFSIDER_ANDROID_TREE is auto when unset or empty, and reads auto, helper and uiautomator in any case")
    func parsing() throws {
        #expect(try Self.mode(nil) == .auto)
        #expect(try Self.mode("") == .auto)
        #expect(try Self.mode("auto") == .auto)
        #expect(try Self.mode("helper") == .helper)
        #expect(try Self.mode("UIAutomator") == .uiautomator)
    }

    @Test("any other value is refused with the values Offsider reads, before any device work")
    func invalid() async throws {
        #expect(throws: AndroidError.invalidSetting(variable: "OFFSIDER_ANDROID_TREE", value: "xyz", expected: "auto, helper or uiautomator")) {
            try Self.mode("xyz")
        }
        let rig = try HelperRig(environment: ["OFFSIDER_ANDROID_TREE": "xyz"])
        let error = await #expect(throws: AndroidError.self) { try await rig.read() }
        #expect(error?.message == "OFFSIDER_ANDROID_TREE is xyz, which Offsider cannot read. Use auto, helper or uiautomator, or unset it.")
        #expect(rig.server.connectionAttempts == 0)
    }

    @Test("forced uiautomator never starts the helper and warns about nothing")
    func forcedUIAutomator() async throws {
        let rig = try HelperRig(environment: ["OFFSIDER_ANDROID_TREE": "uiautomator"])
        let tree = try await rig.read()

        #expect(tree.roots.first?.children.first?.id == "BackButton")
        #expect(rig.startShells == 0)
        #expect(rig.uiautomatorDumps == 1)
        #expect(rig.log.warnings.isEmpty)
    }

    @Test("an unavailable helper falls back to uiautomator with exactly one warning, however many reads follow")
    func fallbackWarnsOnce() async throws {
        let rig = try HelperRig(FakeHelperDevice(starts: [.exit(status: 6, stderr: "java.lang.VerifyError: bad dex\n")]))
        for _ in 0..<3 {
            _ = try await rig.read()
        }

        #expect(rig.startShells == 1)
        #expect(rig.uiautomatorDumps == 3)
        #expect(rig.log.warnings == [
            "The UiAutomation helper is unavailable on emulator-5556 (it exited with status 6 before it was ready: java.lang.VerifyError: bad dex). Reading the screen with uiautomator instead, which takes about 2 s per read.",
        ])
    }

    @Test("a missing bundle falls back and says to reinstall")
    func notBundled() async throws {
        let rig = try HelperRig(dex: nil)
        _ = try await rig.read()
        #expect(rig.startShells == 0)
        #expect(rig.log.warnings == [
            "The UiAutomation helper is unavailable on emulator-5556 (Offsider's resource bundle has no helper; reinstall Offsider). Reading the screen with uiautomator instead, which takes about 2 s per read.",
        ])
    }

    @Test("forced helper turns an unavailable helper into an error")
    func forcedHelper() async throws {
        let rig = try HelperRig(FakeHelperDevice(starts: [.silent]), environment: ["OFFSIDER_ANDROID_TREE": "helper"])
        let error = await #expect(throws: AndroidError.self) { try await rig.read() }
        #expect(error?.kind == .helperUnavailable)
        #expect(error?.message == "The UiAutomation helper is unavailable on emulator-5556 (it did not start within 30 s), and OFFSIDER_ANDROID_TREE is helper. Unset it to fall back to uiautomator.")
        #expect(rig.uiautomatorDumps == 0)
    }

    @Test("a busy slot never falls back, with the helper forced or not", arguments: [[:], ["OFFSIDER_ANDROID_TREE": "helper"]])
    func busyNeverFallsBack(environment: [String: String]) async throws {
        let busy = FakeHelperDevice.Start.exit(status: 4, stdout: HelperLauncherTests.busyJSON + "\n")
        let rig = try HelperRig(FakeHelperDevice(starts: [busy]), environment: environment)
        let error = await #expect(throws: AndroidError.self) { try await rig.read() }

        #expect(error?.kind == .helperBusy)
        #expect(rig.uiautomatorDumps == 0)
        #expect(rig.log.warnings.isEmpty)
    }

    @Test("a failure after the helper served a read is an error, never a switch to uiautomator")
    func noFallbackMidCommand() async throws {
        let device = FakeHelperDevice()
        device.answer = { _, op, json in op == "dump" && json.contains(#""id":3"#) ? .error(code: "dump-failed", message: "getWindows threw") : nil }
        let rig = try HelperRig(device)
        _ = try await rig.read()

        let error = await #expect(throws: AndroidError.self) { try await rig.read() }
        #expect(error?.kind == .helperFailed)
        #expect(rig.uiautomatorDumps == 0)
    }
}
