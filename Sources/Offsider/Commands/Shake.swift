import ArgumentParser
import Foundation
import OffsiderCore

struct Shake: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Send the shake gesture to the simulator (iOS only).",
        discussion: """
        Apps receive it as a motion-shake event, for example to open a React Native dev menu. \
        Fire-and-forget: check the effect with describe-ui or screenshot.

        Example:
          offsider shake --device DEVICE_ID
        """
    )

    static let androidMessage = "shake is iOS only: Android emulators have no shake event. To open a React Native dev menu, run offsider rn devmenu (it sends the menu key, as offsider button menu does)."

    @OptionGroup
    var deviceOption: DeviceOption

    func validate() throws {
        try CLIError.refuseOnPhone(deviceOption.id, command: "shake", alternative: "Shake the device by hand, or use an iOS simulator.")
        if DeviceIDClassifier.classify(deviceOption.id).platform == .android {
            throw ValidationError(Self.androidMessage)
        }
    }

    func run() async throws {
        let logger = OffsiderLogger()
        let route = try await DeviceRouter.routeForInput(deviceOption, logger: logger)
        guard let shaker = route.backend as? any DeviceShaking else {
            throw ValidationError(Self.androidMessage)
        }
        try await shaker.prepare()
        let device = try await shaker.requireBootedDevice(route.device).id
        try await shaker.shake(device)
        print("Shake sent")
    }
}
