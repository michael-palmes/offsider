import Foundation
import OffsiderCore
import Testing
@testable import OffsiderAndroid

@Suite("Android device claims")
@MainActor
struct AndroidDeviceClaimTests {
    final class ClaimSpy: @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [(serial: String, servicesBefore: Int)] = []
        var claims: [(serial: String, servicesBefore: Int)] { lock.withLock { recorded } }
        func record(_ serial: String, services: Int) { lock.withLock { recorded.append((serial, services)) } }
    }

    private func rig(environment: [String: String] = [:], claim: @escaping @Sendable (String) async throws -> Void) throws -> (AndroidBackend, FakeHelperDevice, FakeAdbServer) {
        let device = FakeHelperDevice()
        device.other = { service in
            if service.hasSuffix(AndroidDisplayGeometry.probeScript) { return FakeAdbServer.shell(stdout: AndroidBackendTests.geometryOutput) }
            if service.contains("uiautomator dump") { return FakeAdbServer.shell(stdout: AndroidBackendTreeTests.dump(rotation: 0)) }
            return FakeAdbServer.shell()
        }
        let server = device.server()
        var host = AndroidTestHost.make(
            home: try AndroidTestHost.homeWithSDK(), environment: environment, adb: server,
            liveProcesses: [50144], helperDex: FakeHelperDevice.dex
        )
        host.claimDevice = claim
        return (AndroidBackend(host: host, log: LogRecorder().log), device, server)
    }

    @Test("choosing a tree source claims the device before the helper starts, once per command")
    func claimsBeforeHelper() async throws {
        final class ServerBox: @unchecked Sendable { var server: FakeAdbServer? }
        let spy = ClaimSpy()
        let box = ServerBox()
        let (backend, device, server) = try rig { serial in
            spy.record(serial, services: box.server?.services.filter { $0.contains("app_process") }.count ?? -1)
        }
        box.server = server

        _ = try await backend.accessibilityTree(for: HelperRig.device, point: nil)
        _ = try await backend.accessibilityTree(for: HelperRig.device, point: nil)
        await backend.close()

        #expect(spy.claims.map(\.serial) == ["emulator-5556"])
        #expect(spy.claims.first?.servicesBefore == 0)
        #expect(device.ops.first == "hello")
    }

    @Test("the uiautomator fallback is claimed too")
    func claimsUIAutomator() async throws {
        let spy = ClaimSpy()
        let (backend, _, _) = try rig(environment: ["OFFSIDER_ANDROID_TREE": "uiautomator"]) { spy.record($0, services: 0) }
        _ = try await backend.accessibilityTree(for: HelperRig.device, point: nil)
        await backend.close()
        #expect(spy.claims.map(\.serial) == ["emulator-5556"])
    }

    @Test("a refused claim starts no helper and fails with exit 8")
    func refusedClaim() async throws {
        let (backend, device, server) = try rig { serial in
            throw DeviceBusy(device: serial, command: "describe-ui", holder: DeviceLockHolder(pid: 4242, command: "batch", startedAt: nil), waited: nil)
        }
        let error = await #expect(throws: DeviceBusy.self) {
            _ = try await backend.accessibilityTree(for: HelperRig.device, point: nil)
        }
        await backend.close()
        #expect(error?.exitCode == .deviceBusy)
        #expect(server.services.allSatisfy { !$0.contains("app_process") && !$0.contains("uiautomator") })
        #expect(device.ops.isEmpty)
    }
}
