import Foundation
import OffsiderCore
import OffsiderIOSDevice
import Testing

@Suite("iOS device backend")
@MainActor
struct IOSDeviceBackendTests {
    static let phone = DeviceID(rawValue: IOSDeviceFixtures.phone, platform: .ios)
    static let preparedMarker = "/Users/tester/Library/Developer/Xcode/iOS DeviceSupport/iPhone16,2 27.2 (24B5089g)/.processed_dyld_shared_cache_arm64e"

    static func backend(_ devicectl: FakeDevicectl, existing: Set<String> = []) -> IOSDeviceBackend {
        IOSDeviceBackend(host: .fake(devicectl, existing: existing)) { _, _ in }
    }

    static func reason(_ error: (any Error)?) -> FailureReason? {
        (error as? IOSDeviceError)?.reason
    }

    @Test("list rows are physical iOS devices labelled by model, with USB or network and the readiness state")
    func summaries() async throws {
        let devicectl = try FakeDevicectl.listing("devicectl-list-xcode27-disconnected.json")
        let rows = try await Self.backend(devicectl, existing: [Self.preparedMarker]).listDevices()
        #expect(rows == [DeviceSummary(
            id: IOSDeviceFixtures.phone,
            platform: .ios,
            state: "Reconnecting",
            name: "Apple iPhone 15 Pro Max",
            osVersion: "iOS 27.2",
            deviceType: "iPhone 15 Pro Max",
            kind: .physical,
            connection: "network"
        )])
        #expect(devicectl.calls == [["list", "devices", "--json-output", "-", "--timeout", "9", "-q"]])
    }

    @Test("without the prepared marker a device missing its developer services is preparing")
    func preparing() async throws {
        let rows = try await Self.backend(try FakeDevicectl.listing("devicectl-list-xcode27-disconnected.json")).listDevices()
        #expect(rows.map(\.state) == ["Preparing"])
    }

    @Test("a wired, trusted phone with the tunnel down is woken once, and the listing is read once per command")
    func wiredPhoneWakesOnce() async throws {
        let devicectl = try FakeDevicectl.listing("devicectl-list-xcode26.json")
        let backend = Self.backend(devicectl)
        _ = try await backend.listDevices()
        let booted = try await backend.requireBootedDevice(Self.phone)
        _ = try await backend.requireBootedDevice(Self.phone)

        #expect(booted.name == "Apple iPhone 15 Pro Max")
        let wakes = devicectl.calls.filter { $0.starts(with: ["device", "info", "ddiServices"]) }
        #expect(wakes == [["device", "info", "ddiServices", "--device", IOSDeviceFixtures.phone, "--timeout", "20", "--json-output", "-", "-q"]])
        #expect(devicectl.calls.filter { $0.first == "list" }.count == 2)
    }

    @Test("a phone on Wi-Fi is refused with device_not_wired and never woken")
    func wirelessRefused() async throws {
        let devicectl = try FakeDevicectl.listing("devicectl-list-xcode27-connected.json")
        let error = await #expect(throws: IOSDeviceError.self) {
            _ = try await Self.backend(devicectl).requireBootedDevice(Self.phone)
        }
        #expect(error?.reason == .deviceNotWired)
        #expect(error?.message.contains("Apple iPhone 15 Pro Max (\(IOSDeviceFixtures.phone))") == true)
        #expect(error?.reason.exitCode == .deviceUnavailable)
        #expect(devicectl.calls.allSatisfy { $0.first == "list" })
    }

    @Test("an untrusted iPad is refused with device_untrusted")
    func untrusted() async throws {
        let error = await #expect(throws: IOSDeviceError.self) {
            _ = try await Self.backend(try FakeDevicectl.listing("devicectl-list-xcode26.json"))
                .requireBootedDevice(DeviceID(rawValue: IOSDeviceFixtures.iPad, platform: .ios))
        }
        #expect(error?.reason == .deviceUntrusted)
    }

    @Test("an unknown UDID is device_not_found with a list-devices hint")
    func notListed() async throws {
        let error = await #expect(throws: IOSDeviceError.self) {
            _ = try await Self.backend(try FakeDevicectl.listing("devicectl-list-xcode26.json"))
                .requireBootedDevice(DeviceID(rawValue: "00008140-0000000000000001", platform: .ios))
        }
        #expect(error?.reason == .deviceNotFound)
        #expect(error?.hint == "offsider list-devices")
    }

    @Test("a failed devicectl names its first stderr line and points at doctor")
    func devicectlFails() async throws {
        let devicectl = FakeDevicectl(replies: ["list": ProcessCaptureResult(status: 1, stdout: "", stderr: "ERROR: CoreDevice is unavailable\nmore\n")])
        let error = await #expect(throws: IOSDeviceError.self) {
            _ = try await Self.backend(devicectl).requireBootedDevice(Self.phone)
        }
        #expect(error?.reason == .commandFailed)
        #expect(error?.message.contains("ERROR: CoreDevice is unavailable") == true)
        #expect(error?.message.contains("more") == false)
        #expect(error?.hint == "offsider doctor")
    }

    @Test("without Xcode the backend is unavailable, so list-devices skips phones quietly")
    func xcodeMissing() async throws {
        let devicectl = FakeDevicectl(xcode: .failure(IOSDeviceError(.xcodeMissing, "No usable Xcode")), replies: [:])
        await #expect(throws: PlatformUnavailable.self) {
            _ = try await Self.backend(devicectl).listDevices()
        }
        #expect(devicectl.calls.isEmpty)
    }
}
