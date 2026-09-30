import Foundation
import OffsiderCore
import Testing
@testable import Offsider
@testable import OffsiderAndroid

/// Forwards to a real backend and counts the input sessions opened through it.
@MainActor
private final class SessionCountingBackend: DeviceBackend {
    let wrapped: AndroidBackend
    private(set) var sessionsOpened = 0

    init(_ wrapped: AndroidBackend) {
        self.wrapped = wrapped
    }

    var platform: DevicePlatform { wrapped.platform }
    func prepare() async throws { try await wrapped.prepare() }
    func listDevices() async throws -> [DeviceSummary] { try await wrapped.listDevices() }
    func requireBootedDevice(_ id: DeviceID) async throws -> BootedDevice { try await wrapped.requireBootedDevice(id) }
    func accessibilityTree(for id: DeviceID, point: UIPoint?) async throws -> UITree { try await wrapped.accessibilityTree(for: id, point: point) }
    func screenInfo(for id: DeviceID) async throws -> UIScreenInfo? { try await wrapped.screenInfo(for: id) }
    func deviceCoordinates(for points: [(x: Double, y: Double)], tree: UITree?, on id: DeviceID) async throws -> [(x: Double, y: Double)] {
        try await wrapped.deviceCoordinates(for: points, tree: tree, on: id)
    }
    func openInputSession(for id: DeviceID) async throws -> any InputSession {
        sessionsOpened += 1
        return try await wrapped.openInputSession(for: id)
    }
    func sendDetachedTouch(_ steps: [DetachedTouchStep], to id: DeviceID) async throws { try await wrapped.sendDetachedTouch(steps, to: id) }
    func screenshotPNG(for id: DeviceID) async throws -> Data { try await wrapped.screenshotPNG(for: id) }
    func volatileScreenBands(for id: DeviceID) async -> ScreenBands { await wrapped.volatileScreenBands(for: id) }
}

@Suite("Android batch session")
@MainActor
struct AndroidBatchSessionTests {
    @Test("a batch opens exactly one input session and one gRPC client for all its steps")
    func oneSessionOneClient() async throws {
        let rig = try AndroidGrpcInputTests.rig()
        let backend = SessionCountingBackend(rig.backend)
        let batch = try Batch.parse([
            "--device", "emulator-5556",
            "--step", "tap -x 200 -y 400",
            "--step", "type 'hi'",
            "--step", "key 40",
            "--step", "button back",
            "--step", "swipe --start-x 200 --start-y 700 --end-x 200 --end-y 300 --duration 0.2",
        ])

        try await batch.run(on: DeviceRouter.Route(backend: backend, device: AndroidGrpcInputTests.device), logger: OffsiderLogger())

        #expect(backend.sessionsOpened == 1)
        #expect(rig.connector.connections.count == 1)
        #expect(rig.emulator.calls.contains(.key(.text("hi"))))
        #expect(rig.emulator.calls.contains(.key(.w3c("GoBack", .press))))
        #expect(rig.adbScripts.isEmpty)
    }
}
