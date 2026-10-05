import ArgumentParser
import Foundation
import OffsiderCore

enum ButtonType: String, CaseIterable, ExpressibleByArgument {
    case applePay = "apple-pay"
    case home = "home"
    case lock = "lock"
    case sideButton = "side-button"
    case siri = "siri"
    case back = "back"
    case appSwitch = "app-switch"
    case volumeUp = "volume-up"
    case volumeDown = "volume-down"


    var hardwareButton: HardwareButton {
        switch self {
        case .applePay: return .applePay
        case .home: return .home
        case .lock: return .lock
        case .sideButton: return .sideButton
        case .siri: return .siri
        case .back: return .back
        case .appSwitch: return .appSwitch
        case .volumeUp: return .volumeUp
        case .volumeDown: return .volumeDown
        }
    }

    var description: String {
        switch self {
        case .applePay: return "Apple Pay button"
        case .home: return "Home button"
        case .lock: return "Lock/Power button"
        case .sideButton: return "Side button"
        case .siri: return "Siri button"
        case .back: return "Back button"
        case .appSwitch: return "App switch button"
        case .volumeUp: return "Volume up button"
        case .volumeDown: return "Volume down button"
        }
    }

    static func names(on platform: DevicePlatform) -> String {
        switch platform {
        case .ios: return "apple-pay, home, lock, side-button, siri"
        case .android: return "back, app-switch, home, lock, volume-up, volume-down"
        }
    }
}

struct Button: AsyncParsableCommand, VerifiableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Press a hardware button on the device.",
        discussion: """
        iOS buttons: apple-pay, home, lock, side-button, siri
        Android buttons: back, app-switch, home, lock (the power key), volume-up, volume-down

        Examples:
          offsider button home --device DEVICE_ID
          offsider button lock --duration 2.0 --device DEVICE_ID
          offsider button back --device emulator-5554
        """
    )

    @Argument(help: "The button to press.")
    var buttonType: ButtonType

    @Option(name: .customLong("duration"), help: "Duration to hold the button in seconds (optional).")
    var duration: Double?

    @OptionGroup
    var verification: VerificationOptions

    @OptionGroup
    var deviceOption: DeviceOption

    func validate() throws {
        if let duration = duration {
            guard duration > 0 else {
                throw ValidationError("Duration must be greater than 0.")
            }
            guard duration <= 10.0 else {
                throw ValidationError("Duration must not exceed 10 seconds.")
            }
        }
        let classification = DeviceIDClassifier.classify(deviceOption.id)
        if let platform = classification.platform {
            try Self.checkAvailability(buttonType, on: platform, device: deviceOption.id)
        }
        if case .iosDevice(let udid) = classification, buttonType == .applePay {
            throw ValidationError("The apple-pay button needs an iOS simulator, and \(udid) is a physical iPhone or iPad. iPhone buttons: home, lock, side-button, siri.")
        }
    }

    /// A usage error (exit 64) when the device's platform has no such button.
    static func checkAvailability(_ button: ButtonType, on platform: DevicePlatform, device: String) throws {
        guard !button.hardwareButton.platforms.contains(platform) else { return }
        switch platform {
        case .android:
            throw ValidationError("The \(button.rawValue) button is iOS only, and \(device) is an Android emulator. Android buttons: \(ButtonType.names(on: .android)).")
        case .ios:
            throw ValidationError("The \(button.rawValue) button is Android only, and \(device) is an iOS simulator. iOS buttons: \(ButtonType.names(on: .ios)).")
        }
    }

    func run() async throws {
        if buttonType == .home, duration == nil, DeviceIDClassifier.classify(deviceOption.id).platform == .android {
            try await pressAndroidHome()
            return
        }
        guard verification.verify else {
            try await execute(progress: nil)
            return
        }
        try await VerifyOutput.reportingFailures(command: "button", target: buttonType.rawValue, options: verification) { progress in
            try await execute(progress: progress)
        }
    }

    /// Android `home` confirms the launcher came to the front, sending the HOME intent once when the key was ignored.
    @MainActor
    private func pressAndroidHome() async throws {
        let route = try await DeviceRouter.routeForInput(deviceOption, logger: OffsiderLogger())
        try await route.backend.prepare()
        guard let backend = route.backend as? any ForegroundReading else {
            try await route.backend.performTracked(.shortButtonPress(.home), on: route.device)
            return
        }
        let device = route.device
        let run = { try await Self.pressHome(on: backend, device: device, verification: verification) }
        guard verification.verify else {
            try await run()
            return
        }
        try await VerifyOutput.reportingFailures(command: "button", target: buttonType.rawValue, options: verification) { progress in
            progress.attempts = 1
            try await run()
        }
    }

    /// Without --verify a launcher that never came up is a warning; with it, exit 5 (`not_verified`) and a report with `change: activity`.
    @MainActor
    static func pressHome(
        on backend: any ForegroundReading,
        device: DeviceID,
        verification: VerificationOptions,
        sleep: (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        writeOutput: (String) -> Void = { print($0) },
        writeError: (String) -> Void = { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }
    ) async throws {
        let outcome = try await HomePress.run(
            read: { try await backend.foreground(on: device) },
            sendKey: { try await backend.performTracked(.shortButtonPress(.home), on: device) },
            sendIntent: { try await backend.startHomeIntent(on: device) },
            sleep: sleep
        )
        let launcher = outcome.after.home ?? "the launcher"
        let viaIntent = outcome.via == .intent ? " (the home key was ignored, so Offsider sent the HOME intent)" : ""
        guard verification.verify else {
            if outcome.reached {
                if !viaIntent.isEmpty { writeError("Note: Home button reached \(launcher)\(viaIntent).") }
            } else {
                writeError("Warning: the home key and the HOME intent were sent, but \(outcome.after.top ?? "the app") is still in front.")
            }
            return
        }
        let report = VerifyReport(
            command: "button",
            target: "home",
            dispatched: .yes,
            verified: outcome.reached,
            attempts: 1,
            change: outcome.reached ? .activity : .none,
            note: outcome.via == .intent ? .homeIntent : nil
        )
        let line = outcome.reached
            ? "✓ Home button verified: \(launcher) came to the front\(viaIntent), attempt 1 of 1"
            : "✗ Home button not verified: \(outcome.after.top ?? "the app") is still in front after the home key and the HOME intent."
        if verification.json {
            writeError(line)
            writeOutput(String(decoding: try report.jsonData(), as: UTF8.self))
        } else if outcome.reached {
            writeOutput(line)
        } else {
            writeError(line)
        }
        if report.exitCode != .success {
            throw ExitCode(report.exitCode.rawValue)
        }
    }

    private func execute(progress: VerifyProgress?) async throws {
        let logger = OffsiderLogger()
        let route = try await DeviceRouter.routeForInput(deviceOption, logger: logger)
        let backend = route.backend
        let device = route.device
        try Self.checkAvailability(buttonType, on: device.platform, device: deviceOption.id)
        try await backend.prepare()

        logger.info().log("Pressing \(buttonType.description)")
        if let duration = duration {
            logger.info().log("Duration: \(duration) seconds")
        }

        let buttonEvent: InputEvent
        if let duration = duration {
            buttonEvent = .composite([
                .button(direction: .down, button: buttonType.hardwareButton),
                .delay(duration),
                .button(direction: .up, button: buttonType.hardwareButton)
            ])
        } else {
            buttonEvent = .shortButtonPress(buttonType.hardwareButton)
        }

        if let progress {
            let request = VerifyRequest(
                command: "button",
                subject: buttonType.description,
                target: buttonType.rawValue,
                backend: backend,
                device: device,
                options: verification,
                styles: Array(repeating: nil, count: RetryPolicy.attemptCount(retries: verification.resolvedRetries))
            )
            try await VerifyOutput.perform(request, progress: progress) { _, session in
                try await session.perform(buttonEvent)
            }
            return
        }

        try await backend.performTracked(buttonEvent, on: device)

        logger.info().log("\(buttonType.description) press completed successfully")
    }
}
