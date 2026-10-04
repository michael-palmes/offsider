import Foundation
import OffsiderCore
import Testing
@testable import Offsider
@testable import OffsiderAndroid

@Suite("Android routing")
@MainActor
struct AndroidRoutingTests {
    static func server(_ properties: [String: String]) -> FakeAdbServer {
        let listing = properties.keys.sorted().map { "\($0) device model:sdk_gphone64_arm64 transport_id:1" }.joined(separator: "\n") + "\n"
        return FakeAdbServer(handler: FakeAdbServer.devices(
            Set(properties.keys),
            host: { service in
                switch service {
                case "host:version": return FakeAdbServer.okay(payload: "0029")
                case "host:devices-l": return FakeAdbServer.okay(payload: listing)
                default: return .hang
                }
            },
            device: { serial, _ in FakeAdbServer.shell(stdout: properties[serial] ?? "") }
        ))
    }

    static func host(_ server: FakeAdbServer, home: URL) -> AndroidHost {
        AndroidTestHost.make(home: home, adb: server)
    }

    @Test("an emulator serial routes to Android in canonical form, without any adb traffic")
    func serialRoutesWithoutIO() async throws {
        let server = Self.server([:])
        let route = try await DeviceRouter.route("emulator-05556", logger: OffsiderLogger(), host: Self.host(server, home: try AndroidTestHost.homeWithSDK()))

        #expect(route.backend is AndroidBackend)
        #expect(route.device == DeviceID(rawValue: "emulator-5556", platform: .android))
        #expect(server.connectionAttempts == 0)
    }

    @Test("an AVD name routes to its running serial")
    func avdNameResolves() async throws {
        let server = Self.server(["emulator-5556": "Offsider_E2E_Pixel_9\n\n1\n16\n36\n"])
        let route = try await DeviceRouter.route("Offsider_E2E_Pixel_9", logger: OffsiderLogger(), host: Self.host(server, home: try AndroidTestHost.homeWithSDK()))

        #expect(route.device == DeviceID(rawValue: "emulator-5556", platform: .android))
    }

    @Test("an AVD that is not running, an unknown name and a name running twice are refused before any input")
    func refusals() async throws {
        let home = try AndroidTestHost.homeWithSDK()
        let directory = home.appendingPathComponent(".android/avd/Spare_AVD.avd")
        try AndroidTestHost.write("path=\(directory.path)\n", to: ".android/avd/Spare_AVD.ini", in: home)
        try AndroidTestHost.write("hw.device.name=pixel_9\n", to: ".android/avd/Spare_AVD.avd/config.ini", in: home)
        let server = Self.server(["emulator-5554": "Twin\n\n1\n16\n36\n", "emulator-5556": "Twin\n\n1\n16\n36\n"])
        let host = Self.host(server, home: home)

        let notRunning = await #expect(throws: AndroidError.self) { _ = try await DeviceRouter.route("Spare_AVD", logger: OffsiderLogger(), host: host) }
        #expect(notRunning?.kind == .avdNotRunning)
        let unknown = await #expect(throws: AndroidError.self) { _ = try await DeviceRouter.route("Pixel_10", logger: OffsiderLogger(), host: host) }
        #expect(unknown?.kind == .noDeviceNamed)
        let twice = await #expect(throws: AndroidError.self) { _ = try await DeviceRouter.route("Twin", logger: OffsiderLogger(), host: host) }
        #expect(twice?.kind == .avdRunningTwice)
        #expect(!server.services.contains { $0.contains("input ") })
    }

    @Test("an AVD-shaped name on a Mac without an SDK is simply unknown")
    func noSDK() async throws {
        let server = Self.server([:])
        let error = await #expect(throws: AndroidError.self) {
            _ = try await DeviceRouter.route("Pixel_9", logger: OffsiderLogger(), host: Self.host(server, home: try AndroidTestHost.temporaryHome()))
        }
        #expect(error?.message == "No device named Pixel_9. Run `offsider list-devices` to find device IDs.")
        #expect(server.connectionAttempts == 0)
    }

    @Test("a UUID never builds an Android backend")
    func uuidStaysIOS() async throws {
        let server = Self.server([:])
        let route = try await DeviceRouter.route("abcdef00-0000-4000-8000-00000000abcd", logger: OffsiderLogger(), host: Self.host(server, home: try AndroidTestHost.homeWithSDK()))
        #expect(route.backend is IOSBackend)
        #expect(server.connectionAttempts == 0)
    }

    @Test("every backend the router builds is adopted by the command scope")
    func routerAdoptsWhatItBuilds() async throws {
        let server = Self.server(["emulator-5556": "Offsider_E2E_Pixel_9\n\n1\n16\n36\n"])
        let host = Self.host(server, home: try AndroidTestHost.homeWithSDK())
        let scope = CommandScope()

        let ios = try await DeviceRouter.route("abcdef00-0000-4000-8000-00000000abcd", logger: OffsiderLogger(), host: host, scope: scope)
        let serial = try await DeviceRouter.route("emulator-5556", logger: OffsiderLogger(), host: host, scope: scope)
        let avd = try await DeviceRouter.route("Offsider_E2E_Pixel_9", logger: OffsiderLogger(), host: host, scope: scope)
        let listing = DeviceRouter.allBackends(logger: OffsiderLogger(), host: host, scope: scope)

        let built = [ios.backend, serial.backend, avd.backend] + listing
        #expect(scope.adopted.count == built.count)
        #expect(zip(scope.adopted, built).allSatisfy { $0 === $1 })
    }

    @Test("closing the command scope closes the routed Android backend's gRPC client")
    func scopeClosesRoutedBackend() async throws {
        let rig = try AndroidGrpcInputTests.rig()
        let scope = CommandScope()
        let route = try await DeviceRouter.route("emulator-5556", logger: OffsiderLogger(), host: rig.backend.host, scope: scope)

        try await scope.run {
            try await route.backend.perform(.tapAt(x: 10, y: 20), on: route.device)
        }

        #expect(rig.emulator.calls.last == .close)
    }

    @Test("in a batch, type on Android becomes one text step instead of HID key events")
    func batchTypeIsText() async throws {
        let device = DeviceID(rawValue: "emulator-5556", platform: .android)
        let context = BatchContext(
            backend: try AndroidBackendTests.backend(Self.server([:])),
            device: device,
            axCachePolicy: .perBatch,
            typeSubmissionMode: .chunked,
            typeChunkSize: 1
        )
        let primitives = try await Type.parse(["héllo world", "--device", device.rawValue]).toBatchPrimitives(context: context, logger: OffsiderLogger())

        guard primitives.count == 1, case .text(let text, replace: false) = primitives[0] else {
            Issue.record("expected one text step, got \(primitives)")
            return
        }
        #expect(text == "héllo world")
    }
}

@Suite("Android command refusals")
struct AndroidCommandRefusalTests {
    @Test("doctor --device with an Android ID and no SDK fails android.sdk, skips the device checks and exits 4")
    func doctorChecksAndroidWithoutSDK() async throws {
        let result = try await TestHelpers.runOffsiderWithoutAndroid("doctor --device emulator-5556")
        #expect(result.exitCode == 4)
        #expect(result.stdout.contains("✗ android.sdk"))
        #expect(result.stdout.contains("Android SDK not found"))
        #expect(result.stdout.contains("- android-device.state"))
        #expect(!result.stdout.contains("xcode.developer-dir"))
    }

    @Test("slider on Android is no longer refused: it goes to the emulator, here failing for want of an SDK")
    func sliderReachesAndroid() async throws {
        let result = try await TestHelpers.runOffsiderWithoutAndroid("slider --id volume --value 50 --device emulator-5556")
        #expect(result.exitCode == 9)
        #expect(result.stderr.contains(ListDevicesPlatformFilterTests.sdkNotFound))
        #expect(!result.stderr.contains("not supported"))
    }
}
