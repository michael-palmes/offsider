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

@Suite("Recording refusal")
struct RecordingRefusalTests {
    static let device = DeviceID(rawValue: "emulator-5554", platform: .android)

    @Test("the refusal names the recording's pid and the command that stops it")
    func namesThePid() {
        let error = #expect(throws: CLIError.self) {
            try RecordingMarker.refuseTyping("a password", command: "login", on: Self.device, recordingLive: { _ in true }, recorders: { _ in [4242] })
        }
        #expect(error?.reason == .deviceBusy)
        #expect(error?.failureMessage.contains("pid 4242") == true)
        #expect(error?.hint == "kill -INT 4242")
    }

    @Test("with two recordings it names both")
    func namesBoth() {
        let error = #expect(throws: CLIError.self) {
            try RecordingMarker.refuseTyping("a password", command: "login", on: Self.device, recordingLive: { _ in true }, recorders: { _ in [4242, 4243] })
        }
        #expect(error?.failureMessage.contains("pid 4242 and 4243") == true)
        #expect(error?.hint == "kill -INT 4242 4243")
    }

    @Test("with no pid to name it points at session stop, a whole command")
    func noPid() {
        let error = #expect(throws: CLIError.self) {
            try RecordingMarker.refuseTyping("a password", command: "login", on: Self.device, recordingLive: { _ in true }, recorders: { _ in [] })
        }
        #expect(error?.hint == "offsider session stop --device emulator-5554")
    }

    @Test("with no recording nothing is refused")
    func noRecording() throws {
        try RecordingMarker.refuseTyping("a password", command: "login", on: Self.device, recordingLive: { _ in false }, recorders: { _ in Issue.record("read a pid"); return [] })
    }
}

@Suite("Recording in doctor and session stop")
struct RecordingVisibilityTests {
    @Test("doctor warns of a live recording, names its pid and the command that stops it, and says nothing without one")
    func doctorCheck() throws {
        let root = try RecordingMarkerTests.root()
        defer { try? FileManager.default.removeItem(atPath: root) }
        #expect(Doctor.recordingCheck(platform: .android, lockID: "emulator-5554", root: root).isEmpty)
        let marker = try RecordingMarker.create(DeviceLockKey(platform: .android, id: "emulator-5554"), root: root)
        defer { marker.remove() }
        let check = try #require(Doctor.recordingCheck(platform: .android, lockID: "emulator-5554", root: root, recorders: { _, _ in [4242] }).first)
        #expect(check.id == .deviceRecording && check.status == .warn)
        #expect(check.detail.contains("pid 4242"))
        #expect(check.hint == "offsider session stop --device emulator-5554")
    }

    @Test("session stop's JSON says when a recording is still running, and stays silent otherwise")
    func sessionStopRunning() throws {
        let running = try #require(try JSONSerialization.jsonObject(with: Data(DeviceSessionRow.stoppedJSON([], recordingRunning: true).utf8)) as? [String: Any])
        #expect(running["recordingRunning"] as? Bool == true)
        let clean = try #require(try JSONSerialization.jsonObject(with: Data(DeviceSessionRow.stoppedJSON([]).utf8)) as? [String: Any])
        #expect(clean["recordingRunning"] == nil)
    }

    @Test("a stopped recording shows in session stop's text and JSON")
    func sessionStopRow() throws {
        let stopped = DeviceSessionRow.stopped(runners: [], brokers: [], recordings: ["emulator-5554"])
        #expect(DeviceSessionRow.stoppedText(stopped, device: "emulator-5554") == "Stopped the recording on emulator-5554.\n")
        let object = try #require(try JSONSerialization.jsonObject(with: Data(DeviceSessionRow.stoppedJSON(stopped).utf8)) as? [String: Any])
        #expect((object["stopped"] as? [[String: Any]])?.first?["recording"] as? Bool == true)
    }
}
