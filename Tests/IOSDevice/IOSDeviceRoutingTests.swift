import Foundation
import OffsiderCore
import OffsiderIOSDevice
import Testing
@testable import Offsider

@Suite("Physical iOS device routing")
@MainActor
struct IOSDeviceRoutingTests {
    static let phone = "00008130-0000000000000ABC"

    @Test("an iPhone UDID routes to the device backend in canonical uppercase")
    func phoneRoutesToDeviceBackend() async throws {
        let route = try await DeviceRouter.route(" \(Self.phone.lowercased()) ", logger: OffsiderLogger())

        #expect(route.backend is IOSDeviceBackend)
        #expect(route.device == DeviceID(rawValue: Self.phone, platform: .ios))
        #expect(route.device.isPhysicalIOSDevice)
    }

    @Test("list-devices asks the device backend too")
    func allBackendsIncludePhones() {
        let backends = DeviceRouter.allBackends(logger: OffsiderLogger())
        #expect(backends.contains { $0 is IOSDeviceBackend })
        #expect(backends.contains { $0 is IOSBackend })
    }

    @Test("simulator-only commands refuse a phone with not_supported before any device work", arguments: [
        ("shake", "shake"),
        ("status-bar clear", "status-bar"),
        ("biometric status", "biometric"),
        ("permission grant camera --app com.example.app", "permission"),
        ("permission show --app com.example.app", "permission"),
    ])
    func simulatorOnlyCommandsRefusePhones(command: String, name: String) async throws {
        let result = try await TestHelpers.runOffsiderWithoutAndroid("\(command) --device \(Self.phone)")
        #expect(result.exitCode == 1)
        #expect(result.stderr.contains("\(name) does not work on a physical iPhone or iPad, and \(Self.phone) is one."))
    }

    @Test("apple-pay is a usage error on a phone; boot points at the cable")
    func applePayAndBoot() async throws {
        let button = try await TestHelpers.runOffsiderWithoutAndroid("button apple-pay --device \(Self.phone)")
        #expect(button.exitCode == 64)
        #expect(button.stderr.contains("The apple-pay button needs an iOS simulator"))

        let boot = try await TestHelpers.runOffsiderWithoutAndroid("boot \(Self.phone)")
        #expect(boot.exitCode == 64)
        #expect(boot.stderr.contains("is a physical iPhone or iPad"))
    }

    @Test("list-devices explains every iPhone it cannot drive yet, by model and UDID", arguments: [
        ("Untrusted", "usb", "tap Trust"),
        ("Developer Mode off", "usb", "turn it on in Settings"),
        ("Preparing", "usb", "prepared for development"),
        ("Unavailable", nil, "paired but not connected"),
        ("Wireless", "network", "connect its cable"),
        ("Reconnecting", "network", "connect its cable"),
    ] as [(String, String?, String)])
    func phoneHints(state: String, connection: String?, advice: String) {
        let row = DeviceSummary(id: Self.phone, platform: .ios, state: state, name: "Apple iPhone 15 Pro Max", osVersion: "iOS 27.2", deviceType: "iPhone 15 Pro Max", kind: .physical, connection: connection)
        let hints = ListDevices.phoneHints([row])
        #expect(hints.count == 1)
        #expect(hints.first?.hasPrefix("Apple iPhone 15 Pro Max (\(Self.phone))") == true)
        #expect(hints.first?.contains(advice) == true)
    }

    @Test("a ready wired iPhone needs no hint")
    func readyPhoneHasNoHint() {
        let row = DeviceSummary(id: Self.phone, platform: .ios, state: "Booted", name: "Apple iPhone 15 Pro Max", osVersion: nil, deviceType: nil, kind: .physical, connection: "usb")
        #expect(ListDevices.phoneHints([row]).isEmpty)
    }

    @Test("the other buttons pass the phone check", arguments: ["home", "lock", "side-button", "siri"])
    func otherButtonsPass(button: String) throws {
        _ = try Button.parse([button, "--device", Self.phone])
    }
}
