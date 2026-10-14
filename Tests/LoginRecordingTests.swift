import Foundation
import OffsiderCore
@testable import Offsider
import Testing

@Suite("Login during a recording")
struct LoginRecordingTests {
    @Test("login refuses with device_busy while record-video records the device, before reading the screen or the Keychain")
    @MainActor
    func refusedWhileRecording() async throws {
        let root = try RecordingMarkerTests.root()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let device = DeviceID(rawValue: "emulator-5554", platform: .android)
        let marker = try RecordingMarker.create(DeviceLockKey(platform: .android, id: "emulator-5554"), root: root)
        defer { marker.remove() }
        let backend = FakeDeviceBackend(platform: .android, trees: [])
        let store = MemoryLoginCredentialStore()

        let error = await #expect(throws: CLIError.self) {
            _ = try await LoginCommand.perform(
                on: DeviceRouter.Route(backend: backend, device: device), profile: nil, key: "dev", timeout: 5, logger: OffsiderLogger(), store: store,
                recordingLive: { RecordingMarker.isLive($0, root: root) }
            )
        }

        #expect(error?.reason == .deviceBusy)
        #expect(error?.reason.exitCode.rawValue == 8)
        #expect(error?.failureMessage.contains("A recording is running on emulator-5554 (record-video or stream-video), so login will not type a password until it stops") == true)
        #expect(backend.treeReads == 0)
    }
}
