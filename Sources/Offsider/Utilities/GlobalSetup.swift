import Foundation
import FBControlCore
import FBSimulatorControl

@MainActor
func performGlobalSetup(logger: OffsiderLogger) async throws {
    logger.info().log("Performing global setup...")

    // Check Xcode availability
    logger.info().log("Checking Xcode availability...")
    do {
        let xcodePath = try FBXcodeDirectory.resolveDeveloperDirectory()
        if xcodePath.isEmpty {
            let errorMessage = "Offsider could not find an active Xcode installation. Select Xcode with `xcode-select` or set `DEVELOPER_DIR`, then try again."
            logger.error().log(errorMessage)
            throw CLIError(errorDescription: errorMessage, reason: .xcodeMissing, hint: "xcode-select -s <Xcode.app>/Contents/Developer")
        }
        logger.info().log("Xcode is available at: \(xcodePath)")
    } catch let error as CLIError {
        throw error
    } catch {
        let errorMessage = "Offsider could not resolve the active Xcode installation: \(error.localizedDescription)"
        logger.error().log(errorMessage)
        throw CLIError(errorDescription: errorMessage, reason: .xcodeMissing, hint: "xcode-select -s <Xcode.app>/Contents/Developer")
    }

    // Load essential private frameworks
    logger.info().log("Loading essential private frameworks via FBSimulatorControlFrameworkLoader...")
    do {
        try FBSimulatorControlFrameworkLoader.essentialFrameworks.loadPrivateFrameworks(logger)
        logger.info().log("Successfully loaded essential private frameworks (according to FBSimulatorControlFrameworkLoader).")

        // Load Xcode frameworks (including SimulatorKit)
        logger.info().log("Loading Xcode frameworks (including SimulatorKit)...")
        try FBSimulatorControlFrameworkLoader.xcodeFrameworks.loadPrivateFrameworks(logger)
        logger.info().log("Successfully loaded Xcode frameworks.")
    } catch {
        let errorMessage = "Offsider could not load simulator support from the selected Xcode installation: \(error.localizedDescription)"
        logger.error().log(errorMessage)
        throw CLIError(errorDescription: errorMessage, reason: .xcodeUnusable, hint: "xcode-select -s <Xcode.app>/Contents/Developer")
    }
    logger.info().log("Global setup complete.")
} 

@MainActor
func setup(logger: OffsiderLogger) async throws {
    // Check Xcode availability
    do {
        let developerDirectory = try FBXcodeDirectory.resolveDeveloperDirectory()
        if developerDirectory.isEmpty {
            logger.error().log("No active Xcode developer directory was found")
            throw CLIError(
                errorDescription: "Offsider could not find an active Xcode installation. Select Xcode with `xcode-select` or set `DEVELOPER_DIR`, then try again.",
                reason: .xcodeMissing, hint: "xcode-select -s <Xcode.app>/Contents/Developer"
            )
        }
    } catch let error as CLIError {
        throw error
    } catch {
        logger.error().log("Failed to resolve the active Xcode installation: \(error.localizedDescription)")
        throw CLIError(
            errorDescription: "Offsider could not find an active Xcode installation. Select Xcode with `xcode-select` or set `DEVELOPER_DIR`, then try again.",
            reason: .xcodeMissing, hint: "xcode-select -s <Xcode.app>/Contents/Developer"
        )
    }
    
    // Load essential frameworks
    do {
        try FBSimulatorControlFrameworkLoader.essentialFrameworks.loadPrivateFrameworks(logger)
    } catch {
        logger.error().log("Failed to load simulator support: \(error.localizedDescription)")
        throw CLIError(
            errorDescription: "Offsider could not load simulator support from the selected Xcode installation. Confirm Xcode 26 or later is selected and try again.",
            reason: .xcodeUnusable, hint: "xcode-select -s <Xcode.app>/Contents/Developer"
        )
    }
}
