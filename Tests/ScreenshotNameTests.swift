import Foundation
import OffsiderCore
import Testing
@testable import Offsider

@Suite("Screenshot default names", .personOutput)
@MainActor
struct ScreenshotNameTests {
    static let simulator = DeviceID(rawValue: "00000000-0000-0000-0000-000000000001", platform: .ios)
    static let iPhone = DeviceID(rawValue: "00008130-0000000000000ABC", platform: .ios)
    static let emulator = DeviceID(rawValue: "emulator-5554", platform: .android)
    static let phone = DeviceID(rawValue: "0123456789ABCDEF", platform: .android)

    @Test("a physical iPhone, iPad or Android phone's capture is a Screenshot, never a simulator's or emulator's", arguments: [
        (simulator, "Simulator Screenshot"), (iPhone, "Screenshot"), (emulator, "Emulator Screenshot"), (phone, "Screenshot"),
    ])
    func prefix(device: DeviceID, expected: String) {
        #expect(ScreenCapture.defaultPrefix(for: device) == expected)
    }

    /// Takes a screenshot into a fresh folder and returns the one file name it wrote there.
    static func capturedName(on device: DeviceID, arguments: [String] = []) async throws -> String {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("offsider-name-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let backend = FakeDeviceBackend(
            platform: device.platform, trees: [FakeUI.tree(width: 390, height: 844, [])], screenshots: [try ScreenshotMaskTests.whitePNG()], screen: ScreenshotMaskTests.screen
        )
        let command = try Screenshot.parse(["--output", folder, "--device", device.rawValue] + arguments)
        let masks = try command.maskPlan(environment: ["OFFSIDER_MASK_SECURE": "0"])
        _ = try await command.take(try command.request(), on: DeviceRouter.Route(backend: backend, device: device), masks: masks, plain: true)
        return try #require(try FileManager.default.contentsOfDirectory(atPath: folder).first)
    }

    @Test("a USB Android phone's capture is named Screenshot, as the device sent it and when scaled", arguments: [[String](), ["--scale", "points"]])
    func phoneName(arguments: [String]) async throws {
        let name = try await Self.capturedName(on: Self.phone, arguments: arguments)
        #expect(name.hasPrefix("Screenshot - Fake - "))
        #expect(name.hasSuffix(".png"))
    }

    @Test("an emulator's, a simulator's and a physical iPhone's captures keep their own names")
    func otherNames() async throws {
        #expect(try await Self.capturedName(on: Self.emulator).hasPrefix("Emulator Screenshot - Fake - "))
        #expect(try await Self.capturedName(on: Self.simulator).hasPrefix("Simulator Screenshot - Fake - "))
        #expect(try await Self.capturedName(on: Self.iPhone).hasPrefix("Screenshot - Fake - "))
    }
}
