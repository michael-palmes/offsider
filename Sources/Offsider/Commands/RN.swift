import ArgumentParser
import Foundation
import OffsiderCore

struct RN: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "rn",
        abstract: "React Native helpers.",
        subcommands: [RNPrepare.self]
    )
}

struct RNPrepare: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "prepare",
        abstract: "Mark the Expo dev client's first-launch intro as seen, so a fresh debug install opens straight into the app.",
        discussion: """
        Run it after installing an Expo dev client (a Debug build with expo-dev-client) and before launching it. \
        It also stops the dev menu opening by itself at launch. On iOS it writes the app's own preferences on the simulator; \
        on Android it stops the app and writes them with run-as, which needs a debuggable build. \
        Plain React Native and Release builds have no intro and are refused.

        Example:
          offsider rn prepare --bundle-id com.example.app --device DEVICE_ID
        """
    )

    @Option(name: .customLong("bundle-id"), help: ArgumentHelp("The app's bundle ID on iOS or package on Android.", valueName: "bundle-id|package"))
    var bundleID: String

    @OptionGroup
    var deviceOption: DeviceOption

    func validate() throws {
        do {
            _ = try ExpoDevClient.validate(appID: bundleID)
        } catch let error as ExpoDevClientError {
            throw ValidationError(error.message)
        }
    }

    func run() async throws {
        let logger = OffsiderLogger()
        let route = try await DeviceRouter.route(deviceOption.id, logger: logger)
        guard let preparer = route.backend as? any ExpoDevClientPreparing else {
            throw CLIError(errorDescription: "rn prepare is not available for \(deviceOption.id).", reason: .notSupported)
        }
        try await preparer.prepare()
        let device = try await preparer.requireBootedDevice(route.device).id
        do {
            try await preparer.prepareExpoDevClient(bundleID, on: device)
        } catch let error as ExpoDevClientError {
            throw CLIError(errorDescription: error.message, reason: .expoDevClientFailed)
        }
        print("Prepared \(bundleID): the Expo dev menu intro is marked as seen and the menu will not open at launch.")
    }
}
