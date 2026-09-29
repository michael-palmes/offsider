import Foundation
import OffsiderCore
import Testing
@testable import Offsider

private struct ListingFailure: LocalizedError {
    let errorDescription: String?
}

@MainActor
private final class ListingBackend: DeviceBackend {
    let platform: DevicePlatform
    private let devices: [DeviceSummary]
    private let failure: String?

    init(_ platform: DevicePlatform, devices: [DeviceSummary] = [], failure: String? = nil) {
        self.platform = platform
        self.devices = devices
        self.failure = failure
    }

    func prepare() async throws {
        if let failure { throw ListingFailure(errorDescription: failure) }
    }
    func listDevices() async throws -> [DeviceSummary] { devices }
    func requireBootedDevice(_ id: DeviceID) async throws -> BootedDevice { BootedDevice(id: id, name: "Stub") }
    func accessibilityTree(for id: DeviceID, point: UIPoint?) async throws -> UITree { UITree(platform: platform, device: id.rawValue, roots: []) }
    func screenInfo(for id: DeviceID) async throws -> UIScreenInfo? { nil }
    func deviceCoordinates(
        for points: [(x: Double, y: Double)],
        tree: UITree?,
        on id: DeviceID
    ) async throws -> [(x: Double, y: Double)] { points }
    func openInputSession(for id: DeviceID) async throws -> any InputSession { RecordingInputSession() }
    func sendDetachedTouch(_ steps: [DetachedTouchStep], to id: DeviceID) async throws {}
    func screenshotPNG(for id: DeviceID) async throws -> Data { Data() }
}

@Suite("Device Listing Tests")
@MainActor
struct DeviceListingTests {
    private let phone = DeviceSummary(
        id: "00000000-0000-4000-8000-000000000001",
        platform: .ios,
        state: "Booted",
        name: "iPhone 17 Pro",
        osVersion: "iOS 27.0",
        deviceType: "iPhone 17 Pro"
    )
    private let pixel = DeviceSummary(id: "Pixel_9", platform: .android, state: "Shutdown", name: "Pixel \"9\"", osVersion: nil, deviceType: nil)

    @Test("the table aligns columns under a fixed header")
    func tableAlignsColumns() {
        let lines = DeviceListRenderer.table([phone, pixel]).split(separator: "\n", omittingEmptySubsequences: false)

        #expect(lines == [
            "PLATFORM  STATE     ID                                    NAME           OS",
            "ios       Booted    00000000-0000-4000-8000-000000000001  iPhone 17 Pro  iOS 27.0",
            "android   Shutdown  Pixel_9                               Pixel \"9\"      -",
            "",
        ])
    }

    @Test("an empty list prints the header only")
    func emptyTableIsHeaderOnly() {
        #expect(DeviceListRenderer.table([]) == "PLATFORM  STATE  ID  NAME  OS\n")
    }

    @Test("JSON keeps schema key order, explicit nulls and escaping")
    func jsonKeepsOrderAndNulls() throws {
        let text = DeviceListRenderer.json([phone, pixel])
        let object = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        let devices = try #require(object["devices"] as? [[String: Any]])

        #expect(object["version"] as? Int == 1)
        #expect(devices.count == 2)
        #expect(devices[0]["deviceType"] as? String == "iPhone 17 Pro")
        #expect(devices[1]["name"] as? String == "Pixel \"9\"")
        #expect(devices[1]["osVersion"] is NSNull)
        #expect(devices[1]["deviceType"] is NSNull)

        let keys = ["\"version\"", "\"devices\"", "\"id\"", "\"platform\"", "\"state\"", "\"name\"", "\"osVersion\"", "\"deviceType\""]
        let offsets = keys.compactMap { text.range(of: $0)?.lowerBound }
        #expect(offsets.count == keys.count)
        #expect(offsets == offsets.sorted())
    }

    @Test("an empty JSON list is a versioned empty array")
    func emptyJSON() throws {
        let object = try #require(try JSONSerialization.jsonObject(with: Data(DeviceListRenderer.json([]).utf8)) as? [String: Any])

        #expect(object["version"] as? Int == 1)
        #expect((object["devices"] as? [Any])?.isEmpty == true)
    }

    @Test("a failing backend warns and the others still list")
    func failingBackendWarns() async throws {
        var warnings: [String] = []
        let devices = try await ListDevices.collect(
            from: [ListingBackend(.ios, failure: "Xcode is missing."), ListingBackend(.android, devices: [pixel])]
        ) { warnings.append($0) }

        #expect(devices == [pixel])
        #expect(warnings == ["Skipped ios devices: Xcode is missing."])
    }

    @Test("the only backend failing is an error, not a warning")
    func onlyBackendFailingThrows() async {
        var warnings: [String] = []
        await #expect(throws: ListingFailure.self) {
            _ = try await ListDevices.collect(from: [ListingBackend(.ios, failure: "Xcode is missing.")]) { warnings.append($0) }
        }
        #expect(warnings.isEmpty)
    }

    @Test("every backend failing names each platform")
    func everyBackendFailingThrows() async {
        let error = await #expect(throws: CLIError.self) {
            _ = try await ListDevices.collect(
                from: [ListingBackend(.ios, failure: "No Xcode."), ListingBackend(.android, failure: "No SDK.")]
            ) { _ in }
        }
        #expect(error?.userFacingDescription == "Could not list devices.\nios: No Xcode.\nandroid: No SDK.")
    }

    @Test("no backends lists nothing without failing")
    func noBackendsListNothing() async throws {
        #expect(try await ListDevices.collect(from: []) { _ in }.isEmpty)
    }
}

@Suite("Simulator Runtime Tests")
struct SimulatorRuntimeTests {
    @Test("iOS runtimes are listed, including the ones iPad simulators run", arguments: [
        "com.apple.CoreSimulator.SimRuntime.iOS-27-0", "com.apple.CoreSimulator.SimRuntime.iOS-18-5",
    ])
    func iosRuntimeIsListed(identifier: String) {
        #expect(SimulatorRuntime.isIOS(runtimeIdentifier: identifier, osVersionName: "iOS 27.0"))
    }

    @Test("watchOS, tvOS and visionOS runtimes are not listed", arguments: [
        ("com.apple.CoreSimulator.SimRuntime.watchOS-11-0", "watchOS 11.0"),
        ("com.apple.CoreSimulator.SimRuntime.tvOS-18-0", "tvOS 18.0"),
        ("com.apple.CoreSimulator.SimRuntime.xrOS-2-0", "visionOS 2.0"),
    ])
    func otherRuntimesAreNotListed(identifier: String, name: String) {
        #expect(!SimulatorRuntime.isIOS(runtimeIdentifier: identifier, osVersionName: name))
    }

    @Test("the runtime identifier decides over the OS name")
    func identifierWins() {
        #expect(!SimulatorRuntime.isIOS(runtimeIdentifier: "com.apple.CoreSimulator.SimRuntime.watchOS-11-0", osVersionName: "iOS 27.0"))
        #expect(SimulatorRuntime.isIOS(runtimeIdentifier: "com.apple.CoreSimulator.SimRuntime.iOS-27-0", osVersionName: "Unknown"))
    }

    @Test("without an identifier the OS name decides", arguments: [
        (nil, "iOS 18.5", true), ("", "iOS 27.0", true), (nil, "watchOS 11.0", false), (nil, "visionOS 2.0", false), (nil, "", false),
    ] as [(String?, String, Bool)])
    func nameIsTheFallback(identifier: String?, name: String, expected: Bool) {
        #expect(SimulatorRuntime.isIOS(runtimeIdentifier: identifier, osVersionName: name) == expected)
    }
}

@Suite("List Devices Platform Filter Tests")
struct ListDevicesPlatformFilterTests {
    @Test("--platform android lists only the header in this build")
    func androidTableIsHeaderOnly() async throws {
        let result = try await TestHelpers.runOffsiderCommandSeparated("list-devices --platform android")

        #expect(result.exitCode == 0)
        #expect(result.stdout == "PLATFORM  STATE  ID  NAME  OS\n")
    }

    @Test("--platform android --json is an empty device list")
    func androidJSONIsEmpty() async throws {
        let result = try await TestHelpers.runOffsiderCommandSeparated("list-devices --platform android --json")
        let object = try #require(try JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any])

        #expect(result.exitCode == 0)
        #expect(object["version"] as? Int == 1)
        #expect((object["devices"] as? [Any])?.isEmpty == true)
    }

    @Test("an unknown --platform is a usage error")
    func unknownPlatformIsUsageError() async throws {
        let result = try await TestHelpers.runOffsiderCommandSeparated("list-devices --platform windows")

        #expect(result.exitCode == 64)
        #expect(result.stderr.contains("ios"))
        #expect(result.stderr.contains("android"))
    }
}
