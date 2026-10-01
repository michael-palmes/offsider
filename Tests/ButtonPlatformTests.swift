import ArgumentParser
import Foundation
import OffsiderCore
import Testing
@testable import Offsider

@Suite("Button platforms")
@MainActor
struct ButtonPlatformTests {
    @Test("an iOS-only button with an Android ID is a usage error before any device work")
    func iosButtonOnAndroidExits64() async throws {
        let result = try await TestHelpers.runOffsiderWithoutAndroid("button siri --device emulator-5556")
        #expect(result.exitCode == 64)
        #expect(result.stderr.contains("The siri button is iOS only, and emulator-5556 is an Android emulator. Android buttons: back, app-switch, home, lock, volume-up, volume-down."))
    }

    @Test("an Android-only button with a simulator UUID is a usage error before any device work")
    func androidButtonOnIOSExits64() async throws {
        let udid = UUID().uuidString
        let result = try await TestHelpers.runOffsiderWithoutAndroid("button back --device \(udid)")
        #expect(result.exitCode == 64)
        #expect(result.stderr.contains("The back button is Android only, and \(udid) is an iOS simulator. iOS buttons: apple-pay, home, lock, side-button, siri."))
    }

    @Test("an AVD name counts as Android for the check", arguments: ["apple-pay", "side-button", "siri"])
    func avdNameIsAndroid(button: String) throws {
        let error = try #require(throws: (any Error).self) { try Button.parse([button, "--device", "Pixel_9"]) }
        #expect(Button.exitCode(for: error) == .validationFailure)
        #expect(Button.message(for: error).contains("The \(button) button is iOS only, and Pixel_9 is an Android emulator."))
    }

    @Test("home and lock pass on both platforms", arguments: [ButtonType.home, .lock])
    func sharedButtonsPass(button: ButtonType) throws {
        try Button.checkAvailability(button, on: .ios, device: "d")
        try Button.checkAvailability(button, on: .android, device: "d")
    }

    @Test("each platform's list names exactly the buttons it has", arguments: DevicePlatform.allCases)
    func listsMatchPlatforms(platform: DevicePlatform) {
        let listed = Set(ButtonType.names(on: platform).components(separatedBy: ", "))
        let available = Set(ButtonType.allCases.filter { $0.hardwareButton.platforms.contains(platform) }.map(\.rawValue))
        #expect(listed == available)
    }

    @Test("a batch step checks the routed backend's platform, whatever the ID looked like")
    func batchStepChecksBackend() async throws {
        let context = BatchContext(
            backend: StubBackend(session: RecordingInputSession()),
            device: DeviceID(rawValue: "Pixel_9", platform: .ios),
            axCachePolicy: .perBatch,
            typeSubmissionMode: .chunked,
            typeChunkSize: 1
        )
        let step = try Button.parse(["back", "--device", "not a device id"])
        await #expect(throws: ValidationError.self) { try await step.toBatchPrimitives(context: context, logger: OffsiderLogger()) }

        let home = try Button.parse(["home", "--device", "not a device id"])
        #expect(try await home.toBatchPrimitives(context: context, logger: OffsiderLogger()).count == 1)
    }
}
