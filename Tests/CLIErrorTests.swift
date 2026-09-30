import Foundation
import Testing
@testable import Offsider

@Suite("CLI Error Tests")
struct CLIErrorTests {
    @Test("String description contains only the user-facing message")
    func stringDescriptionIsUserFacing() {
        let error = CLIError(errorDescription: "Simulator not found.")

        #expect(String(describing: error) == "Simulator not found.")
    }

    @Test("localizedDescription is the message, not Foundation's generic text")
    func localizedDescriptionIsTheMessage() {
        #expect(CLIError(errorDescription: "x").localizedDescription == "x")
    }

    @Test(
        "Every user-facing error carries its message in localizedDescription",
        arguments: [
            TextToHIDEvents.TextConversionError.unsupportedCharacter("💥"),
            ShellTokenizer.TokenizerError.danglingEscape,
            VideoProcessingError.failedToDecodeImage,
            HIDBrokerNotReadyError(),
            ElementResolutionError.notFound(kind: "label", value: "Save"),
            ProcessCaptureTimeoutError(command: "xcrun simctl", timeout: 5),
        ] as [any UserFacingError]
    )
    func localizedDescriptionIsUserFacing(error: any UserFacingError) {
        #expect(error.localizedDescription == error.userFacingDescription)
    }

    @Test("Offsider runtime error types provide user-facing descriptions")
    func offsiderRuntimeErrorsAreUserFacing() {
        #expect(
            String(describing: TextToHIDEvents.TextConversionError.unsupportedCharacter("💥"))
                == "No keycode found for character: '💥'"
        )
        #expect(
            String(describing: ShellTokenizer.TokenizerError.danglingEscape)
                == "Dangling escape sequence in batch step."
        )
        #expect(
            String(describing: VideoProcessingError.failedToDecodeImage)
                == "Offsider could not decode a simulator video frame."
        )
        #expect(
            VideoProcessingError.failedToDecodeImage.localizedDescription
                == "Offsider could not decode a simulator video frame."
        )
        #expect(
            String(describing: HIDBrokerNotReadyError())
                == "Offsider could not establish simulator input. Wait for the simulator to finish booting and try again."
        )
        #expect(
            HIDBrokerNotReadyError().localizedDescription
                == "Offsider could not establish simulator input. Wait for the simulator to finish booting and try again."
        )
    }

    @Test("Broker responses expose only curated errors")
    func brokerResponsesAreUserFacing() {
        let curatedError = CLIError(errorDescription: "A useful recovery message.")
        let frameworkError = NSError(
            domain: "PrivateFramework",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Internal transport implementation detail"]
        )

        #expect(HIDBroker.brokerResponseDescription(for: curatedError) == "A useful recovery message.")
        #expect(HIDBroker.brokerResponseDescription(for: frameworkError) == HIDBroker.inputDeliveryFailureDescription)
        #expect(!HIDBroker.brokerResponseDescription(for: frameworkError).contains("implementation detail"))
    }

    @Test("Missing device errors use public terminology and provide recovery guidance")
    func missingDeviceErrorIsActionable() {
        let error = CLIError.deviceNotFound(id: "EXAMPLE-ID")

        #expect(error.description == "No device with ID EXAMPLE-ID was found. Run `offsider list-devices` to see available devices.")
        #expect(!error.description.contains("set"))
    }

}
