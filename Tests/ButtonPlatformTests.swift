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
        #expect(result.stderr.contains("The siri button is iOS only, and emulator-5556 is an Android emulator. Android buttons: back, app-switch, home, lock, menu, volume-up, volume-down."))
    }

    @Test("an Android-only button with a simulator UUID is a usage error before any device work")
    func androidButtonOnIOSExits64() async throws {
        let udid = UUID().uuidString
        let result = try await TestHelpers.runOffsiderWithoutAndroid("button back --device \(udid)")
        #expect(result.exitCode == 64)
        #expect(result.stderr.contains("The back button is Android only, and \(udid) is an iOS simulator. iOS buttons: apple-pay, app-switch, home, lock, side-button, siri."))
    }

    @Test("an AVD name counts as Android for the check", arguments: ["apple-pay", "side-button", "siri"])
    func avdNameIsAndroid(button: String) throws {
        let error = try #require(throws: (any Error).self) { try Button.parse([button, "--device", "Pixel_9"]) }
        #expect(Button.exitCode(for: error) == .validationFailure)
        #expect(Button.message(for: error).contains("The \(button) button is iOS only, and Pixel_9 is an Android emulator."))
    }

    @Test("home, lock and app-switch pass on both platforms", arguments: [ButtonType.home, .lock, .appSwitch])
    func sharedButtonsPass(button: ButtonType) throws {
        try Button.checkAvailability(button, on: .ios, device: "d")
        try Button.checkAvailability(button, on: .android, device: "d")
    }

    @Test("each platform's list names exactly the buttons it has", arguments: DevicePlatform.allCases)
    func listsMatchPlatforms(platform: DevicePlatform) {
        let listed = Set(ButtonType.names(on: platform).components(separatedBy: ", "))
        let available = Set(ButtonType.allCases.filter { $0.platforms.contains(platform) }.map(\.rawValue))
        #expect(listed == available)
    }

    @Test("the iPhone and iPad list names exactly the buttons a physical device presses")
    func iosDeviceListMatches() {
        let listed = Set(ButtonType.iosDeviceNames.components(separatedBy: ", "))
        #expect(listed == Set(ButtonType.allCases.filter(\.isOnIOSDevice).map(\.rawValue)))
        #expect(!listed.contains("app-switch"))
        #expect(!listed.contains("apple-pay"))
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

@Suite("Button app-switch")
@MainActor
struct ButtonAppSwitchTests {
    static let simulator = DeviceID(rawValue: UUID().uuidString, platform: .ios)
    static let phone = DeviceID(rawValue: "00008130-0000000000000ABC", platform: .ios)

    private static func homePresses(in event: InputEvent) -> (presses: Int, gaps: [TimeInterval])? {
        guard case .composite(let events) = event else { return nil }
        let presses = events.filter { $0 == .shortButtonPress(.home) }.count
        let gaps = events.compactMap { if case .delay(let seconds) = $0 { return seconds } else { return nil } }
        guard presses + gaps.count == events.count else { return nil }
        return (presses, gaps)
    }

    @Test("on an iOS simulator app-switch is one event: Home, a gap of 0.15 to 0.2 s, Home, which lowers to one HID event")
    func simulatorPressesHomeTwice() async throws {
        let session = RecordingInputSession()
        let backend = StubBackend(session: session)

        try await Button.parse(["app-switch", "--device", Self.simulator.rawValue])
            .execute(on: DeviceRouter.Route(backend: backend, device: Self.simulator), progress: nil, logger: OffsiderLogger())

        #expect(session.calls.count == 1)
        guard case .perform(let event)? = session.calls.first, let shape = Self.homePresses(in: event) else {
            Issue.record("expected one composite of Home presses, got \(session.calls)")
            return
        }
        #expect(shape.presses == 2)
        #expect(shape.gaps.count == 1)
        #expect(shape.gaps.allSatisfy { (0.15...0.2).contains($0) })
        guard case .composite = try event.hidEvent() else {
            Issue.record("expected one composite HID event")
            return
        }
    }

    @Test("a batch app-switch step sends the event the command sends")
    func batchMatchesCommand() async throws {
        let session = RecordingInputSession()
        try await Button.parse(["app-switch", "--device", Self.simulator.rawValue])
            .execute(on: DeviceRouter.Route(backend: StubBackend(session: session), device: Self.simulator), progress: nil, logger: OffsiderLogger())
        let context = BatchContext(backend: StubBackend(session: RecordingInputSession()), device: Self.simulator, axCachePolicy: .perBatch, typeSubmissionMode: .composite, typeChunkSize: 1)

        let primitives = try await Button.parse(["app-switch", "--device", Self.simulator.rawValue]).toBatchPrimitives(context: context, logger: OffsiderLogger())

        guard primitives.count == 1, case .hidMergeable(let event) = primitives[0], case .perform(let sent)? = session.calls.first else {
            Issue.record("expected one mergeable event, got \(primitives)")
            return
        }
        #expect(event == sent)
    }

    @Test("--duration with app-switch on an iOS simulator is a usage error before any device work")
    func durationRefusedOnSimulator() async throws {
        let result = try await TestHelpers.runOffsiderWithoutAndroid("button app-switch --duration 1 --device \(UUID().uuidString)")

        #expect(result.exitCode == 64)
        #expect(result.stderr.contains("app-switch on an iOS simulator presses Home twice, so it does not take --duration."))
    }

    @Test("a batch app-switch step with --duration on an iOS backend is refused, and on Android it is a long press")
    func batchDuration() async throws {
        let context = BatchContext(backend: StubBackend(session: RecordingInputSession()), device: Self.simulator, axCachePolicy: .perBatch, typeSubmissionMode: .composite, typeChunkSize: 1)
        let step = try Button.parse(["app-switch", "--duration", "1", "--device", "not a device id"])
        await #expect(throws: ValidationError.self) { try await step.toBatchPrimitives(context: context, logger: OffsiderLogger()) }

        #expect(Button.pressEvent(.appSwitch, duration: 1, on: .android) == .composite([
            .button(direction: .down, button: .appSwitch), .delay(1), .button(direction: .up, button: .appSwitch),
        ]))
        _ = try Button.parse(["app-switch", "--duration", "1", "--device", "emulator-5554"])
    }

    @Test("a physical iPhone or iPad refuses app-switch and lists its buttons")
    func physicalDeviceRefusesAppSwitch() throws {
        let error = try #require(throws: (any Error).self) { try Button.parse(["app-switch", "--device", Self.phone.rawValue]) }

        #expect(Button.exitCode(for: error) == .validationFailure)
        let message = Button.message(for: error)
        #expect(message.contains("The app-switch button needs an iOS simulator or an Android device, and \(Self.phone.rawValue) is a physical iPhone or iPad."))
        #expect(message.contains("iPhone and iPad buttons: home, lock, side-button, siri."))
    }

    @Test("button app-switch --verify presses once by default, since a second press closes the switcher", arguments: ["app-switch", "home"])
    func appSwitchVerifyDoesNotRetry(button: String) throws {
        let command = try Button.parse([button, "--verify", "--device", "emulator-5554"])
        let explicit = try Button.parse([button, "--verify", "--retries", "1", "--device", "emulator-5554"])
        let type = try #require(ButtonType(rawValue: button))

        #expect(Button.verifyRetries(type, command.verification) == (button == "app-switch" ? 0 : 1))
        #expect(Button.verifyRetries(type, explicit.verification) == 1)
    }

    @Test("an Android-only button on a physical iPhone says it is a physical iPhone or iPad, not a simulator", arguments: ["back", "menu", "volume-up"])
    func physicalDeviceWording(button: String) throws {
        let error = try #require(throws: (any Error).self) { try Button.parse([button, "--device", Self.phone.rawValue]) }

        let message = Button.message(for: error)
        #expect(message.contains("The \(button) button is Android only, and \(Self.phone.rawValue) is a physical iPhone or iPad."))
        #expect(!message.contains("simulator"))
    }

    @Test("the routed device decides: a physical iPhone refuses app-switch even when its ID did not look like one")
    func routedPhysicalDeviceRefuses() async throws {
        let session = RecordingInputSession()
        let step = try Button.parse(["app-switch", "--device", "not a device id"])

        await #expect(throws: ValidationError.self) {
            try await step.execute(on: DeviceRouter.Route(backend: StubBackend(session: session), device: Self.phone), progress: nil, logger: OffsiderLogger())
        }
        #expect(session.calls.isEmpty)
    }
}
