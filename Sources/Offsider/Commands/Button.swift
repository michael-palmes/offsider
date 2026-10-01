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
        if let platform = DeviceIDClassifier.classify(deviceOption.id).platform {
            try Self.checkAvailability(buttonType, on: platform, device: deviceOption.id)
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
        guard verification.verify else {
            try await execute(progress: nil)
            return
        }
        try await VerifyOutput.reportingFailures(command: "button", target: buttonType.rawValue, options: verification) { progress in
            try await execute(progress: progress)
        }
    }

    private func execute(progress: VerifyProgress?) async throws {
        let logger = OffsiderLogger()
        let route = try await DeviceRouter.route(deviceOption.id, logger: logger)
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

        try await backend.perform(buttonEvent, on: device)

        logger.info().log("\(buttonType.description) press completed successfully")
    }
}
