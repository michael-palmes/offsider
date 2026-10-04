import Foundation
import OffsiderCore
import Testing
@testable import OffsiderAndroid

@Suite("Android device state")
@MainActor
struct AndroidDeviceStateTests {
    static let device = AndroidBackendTests.device
    nonisolated static let shellPrefix = "shell,v2,raw:"

    static func server(dumpsys: String = "  Package [com.example.app] (1):\n" + PermissionServiceTests.dumpsys, devicesList: String? = nil, reply: @escaping @Sendable (String) -> FakeAdbServer.Reply = { _ in FakeAdbServer.shell() }) -> FakeAdbServer {
        FakeAdbServer(handler: FakeAdbServer.devices(
            ["emulator-5556", "R58M123ABC"],
            host: { service in
                switch service {
                case "host:version": return FakeAdbServer.okay(payload: "0029")
                case "host:devices-l": return devicesList.map { FakeAdbServer.okay(payload: $0) } ?? .hang
                default: return .hang
                }
            },
            device: { _, service in
                let command = service.hasPrefix(shellPrefix) ? String(service.dropFirst(shellPrefix.count)) : service
                if command.hasPrefix("dumpsys package ") { return FakeAdbServer.shell(stdout: dumpsys) }
                return reply(command)
            }
        ))
    }

    static func shellCommands(_ server: FakeAdbServer) -> [String] {
        server.services.filter { $0.hasPrefix(shellPrefix) }.map { String($0.dropFirst(shellPrefix.count)) }
    }

    @Test("a grant is one read and one script")
    func grantRoundTrips() async throws {
        let server = Self.server()
        let backend = try AndroidBackendTests.backend(server)
        let change = try await backend.applyPermission(.grant, [.service(.camera), .service(.location)], app: "com.example.app", on: Self.device)

        #expect(Self.shellCommands(server) == ["dumpsys package com.example.app", "pm grant com.example.app android.permission.CAMERA"])
        #expect(change.targets.map { $0.permissions.map(\.changed) } == [[true], [false, false]])
    }

    @Test("a grant with nothing to change runs only the read")
    func grantNothing() async throws {
        let server = Self.server()
        _ = try await AndroidBackendTests.backend(server).applyPermission(.grant, [.service(.location)], app: "com.example.app", on: Self.device)
        #expect(Self.shellCommands(server) == ["dumpsys package com.example.app"])
    }

    @Test("an uninstalled package fails with the app-not-installed reason")
    func notInstalled() async throws {
        let server = Self.server(dumpsys: "Unable to find package: com.missing.app\n")
        let error = await #expect(throws: AndroidError.self) {
            _ = try await AndroidBackendTests.backend(server).applyPermission(.grant, [.service(.camera)], app: "com.missing.app", on: Self.device)
        }
        #expect(error?.kind == .appNotInstalled)
    }

    @Test("a failing pm grant is an error quoting its stderr")
    func grantFails() async throws {
        let server = Self.server { command in
            command.hasPrefix("pm grant") ? FakeAdbServer.shell(stderr: "Exception occurred while executing 'grant':\n", status: 255) : FakeAdbServer.shell()
        }
        let error = await #expect(throws: AndroidError.self) {
            _ = try await AndroidBackendTests.backend(server).applyPermission(.grant, [.service(.camera)], app: "com.example.app", on: Self.device)
        }
        #expect(error?.message.contains("Exception occurred while executing 'grant':") == true)
    }

    @Test("override reports the earlier demo-allowed value from the same round trip")
    func overrideRoundTrip() async throws {
        let server = Self.server { _ in FakeAdbServer.shell(stdout: "0\n") }
        let previous = try await AndroidBackendTests.backend(server).overrideStatusBar(StatusBarOverride(), on: Self.device)

        #expect(previous.demoAllowed == false)
        #expect(Self.shellCommands(server) == [StatusBarOverride().androidEnterScript])
    }

    @Test("permission and status bar work on a named USB phone")
    func phone() async throws {
        let server = Self.server(devicesList: "R58M123ABC device usb:1-1 model:Pixel_9 transport_id:2\n") { _ in FakeAdbServer.shell(stdout: "null\n") }
        let backend = try AndroidBackendTests.backend(server)
        let phone = DeviceID(rawValue: "R58M123ABC", platform: .android)
        _ = try await backend.requireBootedDevice(phone)
        #expect(try await backend.statusBar(on: phone).demoAllowed == nil)
        _ = try await backend.applyPermission(.grant, [.service(.camera)], app: "com.example.app", on: phone)
        #expect(server.requests.filter { $0.serial == "R58M123ABC" }.count == 3)
    }

    static func biometricBackend(respond: @escaping @Sendable (RecordingProcessRunner.Call) -> ProcessCaptureResult = { _ in ProcessCaptureResult(status: 0, stdout: "OK\n", stderr: "") }) throws -> (AndroidBackend, RecordingProcessRunner, URL) {
        let home = try AndroidTestHost.homeWithSDK()
        let processes = RecordingProcessRunner(respond: respond)
        let host = AndroidTestHost.make(home: home, adb: Self.server(), processes: processes)
        return (AndroidBackend(host: host) { _, _ in }, processes, home)
    }

    @Test("Android match touches then lifts the finger through adb emu with ADB_MDNS=0")
    func matchTouchesThenLifts() async throws {
        let (backend, processes, _) = try Self.biometricBackend()
        let sent = try await backend.sendBiometric(.match, modality: .finger, fingerID: nil, on: Self.device)

        #expect(sent == "finger touch 1")
        let emu = processes.calls.filter { $0.arguments.contains("emu") }
        #expect(emu.map(\.arguments) == [["-s", "emulator-5556", "emu", "finger", "touch", "1"], ["-s", "emulator-5556", "emu", "finger", "remove"]])
        #expect(emu.allSatisfy { $0.environment?["ADB_MDNS"] == "0" && $0.executable.hasSuffix("platform-tools/adb") })
    }

    @Test("no-match touches finger 10 unless another id is given")
    func noMatchFinger() async throws {
        let (backend, processes, _) = try Self.biometricBackend()
        _ = try await backend.sendBiometric(.noMatch, modality: .finger, fingerID: nil, on: Self.device)
        _ = try await backend.sendBiometric(.noMatch, modality: .finger, fingerID: 7, on: Self.device)
        let touches = processes.calls.filter { $0.arguments.contains("touch") }.map { $0.arguments.last }
        #expect(touches == ["10", "7"])
    }

    @Test("a KO reply from the console is an error")
    func consoleKO() async throws {
        let (backend, _, _) = try Self.biometricBackend { _ in ProcessCaptureResult(status: 0, stdout: "KO:  bad sub-command\n", stderr: "") }
        let error = await #expect(throws: AndroidError.self) {
            _ = try await backend.sendBiometric(.match, modality: .finger, fingerID: nil, on: Self.device)
        }
        #expect(error?.message.contains("KO:  bad sub-command") == true)
    }

    @Test("Android enrol refuses with the Settings instructions")
    func enrolRefuses() async throws {
        let (backend, processes, _) = try Self.biometricBackend()
        let error = await #expect(throws: AndroidError.self) { try await backend.setBiometricEnrolment(true, on: Self.device) }
        #expect(error?.message == "Enrolling a fingerprint on Android needs a screen lock, which Offsider does not set. Set a screen lock and add a fingerprint in Settings > Security; when it asks for the sensor, run `offsider biometric match --device emulator-5556`.")
        #expect(processes.calls.allSatisfy { !$0.arguments.contains("emu") })
    }

    @Test("biometric on a physical Android device refuses before any console command")
    func phoneRefuses() async throws {
        let (backend, processes, _) = try Self.biometricBackend()
        let phone = DeviceID(rawValue: "R58M123ABC", platform: .android)
        let error = await #expect(throws: AndroidError.self) {
            _ = try await backend.sendBiometric(.match, modality: .finger, fingerID: nil, on: phone)
        }
        #expect(error?.kind == .unsupportedDevice)
        #expect(error?.message.contains("R58M123ABC is a physical device") == true)
        #expect(processes.calls.allSatisfy { !$0.arguments.contains("emu") })
    }
}
