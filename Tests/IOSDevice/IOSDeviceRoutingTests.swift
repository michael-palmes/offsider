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

    @Test("a simulator-only command refuses a phone with exit 1 before any device work")
    func shakeRefusesPhone() async throws {
        let result = try await TestHelpers.runOffsiderWithoutAndroid("shake --device \(Self.phone)")
        #expect(result.exitCode == 1)
        #expect(result.stderr.contains("shake does not work on a physical iPhone or iPad, and \(Self.phone) is one."))
    }

    @Test("status-bar, biometric and permission refuse a phone with not_supported while parsing", arguments: [
        ["status-bar", "clear"],
        ["biometric", "status"],
        ["permission", "grant", "camera", "--app", "com.example.app"],
        ["permission", "show", "--app", "com.example.app"],
    ])
    func simulatorOnlyCommandsRefusePhones(arguments: [String]) throws {
        let error = try #require(throws: (any Error).self) {
            switch arguments[0] {
            case "status-bar": _ = try StatusBarCommand.parse(Array(arguments.dropFirst()) + ["--device", Self.phone])
            case "biometric": _ = try BiometricCommand.parse(Array(arguments.dropFirst()) + ["--device", Self.phone])
            default: _ = try PermissionCommand.parse(Array(arguments.dropFirst()) + ["--device", Self.phone])
            }
        }
        let failure = try #require(Self.underlying(error) as? CLIError)
        #expect(failure.reason == .notSupported)
        #expect(failure.userFacingDescription.hasPrefix("\(arguments[0]) does not work on a physical iPhone or iPad, and \(Self.phone) is one."))
    }

    /// ArgumentParser may wrap an error thrown from `validate()` in its own error type.
    static func underlying(_ error: any Error) -> any Error {
        Mirror(reflecting: error).descendant("parserError", "userValidationError").flatMap { $0 as? any Error } ?? error
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
        let row = DeviceSummary(id: Self.phone, platform: .ios, state: state, name: "Apple iPhone", osVersion: "iOS 27.2", deviceType: "iPhone", kind: .physical, connection: connection)
        let hints = ListDevices.phoneHints([row])
        #expect(hints.count == 1)
        #expect(hints.first?.hasPrefix("Apple iPhone (\(Self.phone))") == true)
        #expect(hints.first?.contains(advice) == true)
    }

    @Test("a ready wired iPhone needs no hint")
    func readyPhoneHasNoHint() {
        let row = DeviceSummary(id: Self.phone, platform: .ios, state: "Booted", name: "Apple iPhone", osVersion: nil, deviceType: nil, kind: .physical, connection: "usb")
        #expect(ListDevices.phoneHints([row]).isEmpty)
    }

    @Test("the other buttons pass the phone check", arguments: ["home", "lock", "side-button", "siri"])
    func otherButtonsPass(button: String) throws {
        _ = try Button.parse([button, "--device", Self.phone])
    }
}
