import Foundation
import OffsiderCore
import OffsiderIOSDevice
import Testing

@Suite("devicectl failures")
@MainActor
struct DevicectlFailureTests {
    static let phone = IOSDeviceFixtures.phone
    static let mountFailed = "The developer disk image could not be mounted on this device."
    static let firstLine = "ERROR: \(mountFailed) (com.apple.dt.CoreDeviceError error 12040 (0x2F08))"

    /// The JSON `devicectl --json-output -` writes on stdout when a mount fails, with `inner` as the error beneath it.
    static func mountFailure(inner: (code: Int, description: String)?) -> ProcessCaptureResult {
        let underlying = inner.map {
            #","NSUnderlyingError":{"error":{"code":\#($0.code),"domain":"com.apple.dt.CoreDeviceError","userInfo":{"NSLocalizedDescription":{"string":"\#($0.description)"}}}}"#
        } ?? ""
        let stdout = #"{"info":{"outcome":"failed"},"error":{"code":12040,"domain":"com.apple.dt.CoreDeviceError","userInfo":{"NSLocalizedDescription":{"string":"\#(mountFailed)"}\#(underlying)}}}"#
        return ProcessCaptureResult(status: 1, stdout: stdout, stderr: firstLine + "\n")
    }

    static func failure(from reply: ProcessCaptureResult) async -> IOSDeviceError? {
        let directory = IOSDeviceDirectory(host: .fake(FakeDevicectl(replies: ["apps": reply])))
        return await #expect(throws: IOSDeviceError.self) {
            try await directory.installedApps(udid: Self.phone)
        }
    }

    @Test("a mount stopped by the lock is device_locked, with the ask and no raw error")
    func lockedUnderMount() async {
        let error = await Self.failure(from: Self.mountFailure(inner: (10003, "The operation failed because the device was still locked.")))
        #expect(error?.kind == .locked)
        #expect(error?.reason == .deviceLocked)
        #expect(error?.reason.personAsk == "Can you unlock \(PersonAsk.devicePlaceholder)?")
        #expect(error?.message.contains("12040") == false)
    }

    @Test("a mount stopped by Developer Mode is developer_mode_off, not a mount failure")
    func developerModeUnderMount() async {
        let error = await Self.failure(from: Self.mountFailure(inner: (10999, "The operation failed since Developer Mode is turned off on the device.")))
        #expect(error?.reason == .developerModeOff)
        #expect(error?.message.contains("Settings > Privacy & Security > Developer Mode") == true)
    }

    @Test("any other failed mount gives the cause beneath it and says to update Xcode, not to unlock")
    func otherMountFailure() async {
        let error = await Self.failure(from: Self.mountFailure(inner: (12041, "No image matches this hardware.")))
        #expect(error?.kind == .diskImageFailed)
        #expect(error?.message.contains("No image matches this hardware.") == true)
        #expect(error?.message.contains("update Xcode") == true)
        #expect(error?.reason != .deviceLocked)
    }

    @Test("a mount failure with nothing beneath it is still told apart, with the first error as its cause")
    func mountFailureWithoutCause() async {
        let error = await Self.failure(from: Self.mountFailure(inner: nil))
        #expect(error?.kind == .diskImageFailed)
        #expect(error?.message.contains(Self.mountFailed) == true)
    }

    @Test("the cause cannot carry terminal controls or a second line into the message")
    func causeIsCleaned() async {
        let error = await Self.failure(from: Self.mountFailure(inner: (12041, #"Bad \u001b[31mimage\nsecond line"#)))
        #expect(error?.message.contains("\u{1B}") == false)
        #expect(error?.message.contains("\n") == false)
    }

    @Test("an error naming none of these keeps devicectl's own line and the doctor hint", arguments: [
        #"{"error":{"code":1000,"domain":"com.apple.dt.CoreDeviceError","userInfo":{"NSLocalizedDescription":{"string":"The specified device was not found."}}}}"#,
        "not json",
        "",
        #"{"error":{"domain":"no code here"}}"#,
    ])
    func unnamedErrorsStayRaw(stdout: String) async {
        let error = await Self.failure(from: ProcessCaptureResult(status: 1, stdout: stdout, stderr: "ERROR: something else\nmore\n"))
        #expect(error?.kind == .devicectlFailed)
        #expect(error?.message.contains("ERROR: something else") == true)
        #expect(error?.hint == "offsider doctor --device \(Self.phone)")
    }

    @Test("a locked phone met while waking its tunnel fails the next command as device_locked")
    func wakeReportsLocked() async throws {
        let devicectl = try FakeDevicectl.listing("devicectl-list-xcode26.json", extra: [
            "ddiServices": Self.mountFailure(inner: (10003, "The operation failed because the device was still locked.")),
        ])
        let backend = IOSDeviceBackend(host: .fake(devicectl)) { _, _ in }
        let error = await #expect(throws: IOSDeviceError.self) {
            try await backend.requireBootedDevice(DeviceID(rawValue: Self.phone, platform: .ios))
        }
        #expect(error?.reason == .deviceLocked)
    }

    @Test("doctor reports the lock devicectl names, instead of a lock state it could not read")
    func doctorReadsLocked() async throws {
        let devicectl = try FakeDevicectl.listing("devicectl-list-xcode27-disconnected.json", extra: [
            "lockState": Self.mountFailure(inner: (10003, "The operation failed because the device was still locked.")),
        ])
        let facts = await IOSDeviceDoctorProbe(host: .fake(devicectl), xcodeTeams: { [] }).run(udid: Self.phone).facts
        #expect(facts.lock == .locked)
    }

    @Test("the pairing error that already meant locked still does")
    func remotePairingLocked() {
        #expect(CoreDeviceErrorInfo(domain: "com.apple.dt.RemotePairingError", code: 1016).isLocked)
        #expect(!CoreDeviceErrorInfo(domain: "com.apple.dt.CoreDeviceError", code: 1016).isLocked)
        #expect(!CoreDeviceErrorInfo(domain: "com.apple.dt.RemotePairingError", code: 10003).isLocked)
    }
}
