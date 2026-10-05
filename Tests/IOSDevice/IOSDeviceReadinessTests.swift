import Foundation
import OffsiderIOSDevice
import Testing

@Suite("iOS device readiness")
struct IOSDeviceReadinessTests {
    static let ready = DevicectlDevice(
        udid: "00008130-0000000000000ABC",
        marketingName: "iPhone 15 Pro Max",
        productType: "iPhone16,2",
        osVersion: "27.2",
        osBuild: "24B5089g",
        pairingState: "paired",
        transportType: "wired",
        connectionState: "connected",
        tunnelState: "connected",
        developerModeStatus: "enabled",
        ddiServicesAvailable: true
    )

    static func with(_ change: (inout DevicectlDevice) -> Void) -> DevicectlDevice {
        var device = ready
        change(&device)
        return device
    }

    @Test("each problem wins over the ones after it", arguments: [
        (with { $0.connectionState = "unavailable"; $0.pairingState = "unpaired" }, IOSDeviceReadiness.unavailable),
        (with { $0.transportType = nil }, .unavailable),
        (with { $0.pairingState = "unpaired"; $0.developerModeStatus = "disabled" }, .untrusted),
        (with { $0.developerModeStatus = "disabled"; $0.ddiServicesAvailable = false }, .developerModeOff),
        (with { $0.developerModeStatus = nil }, .developerModeOff),
        (with { $0.ddiServicesAvailable = false; $0.transportType = "localNetwork" }, .preparing),
        (with { $0.transportType = "localNetwork" }, .wireless),
        (ready, .ready),
        (with { $0.ddiServicesAvailable = nil }, .ready),
    ])
    func order(device: DevicectlDevice, expected: IOSDeviceReadiness) {
        #expect(IOSDeviceReadiness.assess(device, deviceSupportFinalized: false) == expected)
    }

    @Test("missing developer services on a device Xcode prepared before read as reconnecting")
    func reconnecting() {
        let device = Self.with { $0.ddiServicesAvailable = false }
        #expect(IOSDeviceReadiness.assess(device, deviceSupportFinalized: true) == .reconnecting)
        #expect(IOSDeviceReadiness.blocker(device, deviceSupportFinalized: true) == nil)
    }

    @Test("Wi-Fi blocks a command even while the developer services reconnect")
    func wirelessReconnectingBlocks() {
        let device = Self.with { $0.ddiServicesAvailable = false; $0.transportType = "localNetwork" }
        #expect(IOSDeviceReadiness.blocker(device, deviceSupportFinalized: true) == .wireless)
        #expect(IOSDeviceReadiness.blocker(Self.ready, deviceSupportFinalized: false) == nil)
    }

    @Test("state text for every readiness")
    func stateText() {
        #expect(IOSDeviceReadiness.allCases.map(\.stateText) == [
            "Unavailable", "Untrusted", "Developer Mode off", "Preparing", "Reconnecting", "Wireless", "Booted",
        ])
    }

    @Test("the device support markers sit in the product, version and build folder")
    func markers() {
        let markers = IOSDeviceReadiness.deviceSupportMarkers(for: Self.ready, home: URL(fileURLWithPath: "/Users/tester"))
        #expect(markers.contains("/Users/tester/Library/Developer/Xcode/iOS DeviceSupport/iPhone16,2 27.2 (24B5089g)/.finalized"))
        #expect(markers.contains("/Users/tester/Library/Developer/Xcode/iOS DeviceSupport/iPhone16,2 27.2 (24B5089g)/.processed_dyld_shared_cache_arm64e"))
        #expect(IOSDeviceReadiness.deviceSupportMarkers(for: Self.with { $0.osBuild = nil }, home: URL(fileURLWithPath: "/Users/tester")).isEmpty)
    }
}
