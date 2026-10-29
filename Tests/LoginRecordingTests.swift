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

@Suite("type during a recording")
@MainActor
struct TypeRecordingTests {
    static let device = DeviceID(rawValue: "emulator-5554", platform: .android)

    static func screen(password: Bool) -> UITree {
        FakeUI.tree(platform: .android, [
            FakeUI.node(.textField, id: "email", label: "Email", frame: FakeUI.frame(20, 100, 300, 44), platform: .android),
        ] + (password ? [FakeUI.node(.secureTextField, id: "password", label: "Password", frame: FakeUI.frame(20, 160, 300, 44), platform: .android)] : []))
    }

    @Test("text from stdin or a file is refused with device_busy (exit 8) while a recording runs and a password field is on screen")
    func refusedWithPasswordField() async throws {
        let root = try RecordingMarkerTests.root()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let marker = try RecordingMarker.create(DeviceLockKey(platform: .android, id: Self.device.rawValue), root: root)
        defer { marker.remove() }

        let error = await #expect(throws: CLIError.self) {
            try await Type.refuseSecretDuringRecording(
                backend: FakeDeviceBackend(platform: .android, trees: [Self.screen(password: true)]), device: Self.device,
                recordingLive: { RecordingMarker.isLive($0, root: root) }
            )
        }
        #expect(error?.reason.exitCode.rawValue == 8)
        #expect(error?.failureMessage.contains("A recording is running on emulator-5554 (record-video or stream-video), so type will not type with a password field on screen") == true)

        try await Type.refuseSecretDuringRecording(
            backend: FakeDeviceBackend(platform: .android, trees: [Self.screen(password: false)]), device: Self.device,
            recordingLive: { RecordingMarker.isLive($0, root: root) }
        )
    }

    @Test("without a recording nothing is read")
    func noRecordingNoRead() async throws {
        let backend = FakeDeviceBackend(platform: .android, trees: [Self.screen(password: true)])
        try await Type.refuseSecretDuringRecording(backend: backend, device: Self.device, recordingLive: { _ in false })
        #expect(backend.treeReads == 0)
    }
}
