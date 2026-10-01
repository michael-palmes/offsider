import ArgumentParser
import Foundation
import OffsiderCore

enum ButtonType: String, CaseIterable, ExpressibleByArgument {
    case applePay = "apple-pay"
    case home = "home"
    case lock = "lock"
    case sideButton = "side-button"
    case siri = "siri"
    
    var hardwareButton: HardwareButton {
        switch self {
        case .applePay:
            return .applePay
        case .home:
            return .home
        case .lock:
            return .lock
        case .sideButton:
            return .sideButton
        case .siri:
            return .siri
        }
    }
    
    var description: String {
        switch self {
        case .applePay:
            return "Apple Pay button"
        case .home:
            return "Home button"
        case .lock:
            return "Lock/Power button"
        case .sideButton:
            return "Side button"
        case .siri:
            return "Siri button"
        }
    }
}

struct Button: AsyncParsableCommand, VerifiableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Press a hardware button on the simulator.",
        discussion: """
        Available buttons: apple-pay, home, lock, side-button, siri
        
        Examples:
          offsider button home --udid SIMULATOR_UDID
          offsider button lock --duration 2.0 --udid SIMULATOR_UDID
          offsider button siri --udid SIMULATOR_UDID
        """
    )
    
    @Argument(help: "The button to press.")
    var buttonType: ButtonType
    
    @Option(name: .customLong("duration"), help: "Duration to hold the button in seconds (optional).")
    var duration: Double?
    
    @OptionGroup
    var verification: VerificationOptions

    @Option(name: .customLong("udid"), help: "The UDID of the simulator.")
    var simulatorUDID: String

    func validate() throws {
        // Validate duration if provided
        if let duration = duration {
            guard duration > 0 else {
                throw ValidationError("Duration must be greater than 0.")
            }
            guard duration <= 10.0 else {
                throw ValidationError("Duration must not exceed 10 seconds.")
            }
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
        let route = try await DeviceRouter.route(simulatorUDID, logger: logger)
        let backend = route.backend
        let device = route.device
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

        // Perform the button event
        try await backend.perform(buttonEvent, on: device)
        
        logger.info().log("\(buttonType.description) press completed successfully")
    }
} 
