import Foundation
import FBControlCore
import FBSimulatorControl
import OffsiderCore

/// Refuses a developer directory outside an Apple-signed Xcode before any framework or tool is loaded from it.
func requireTrustedDeveloperDirectory(_ path: String, environment: [String: String] = ProcessInfo.processInfo.environment) throws {
    do {
        try DeveloperDirectoryTrust.shared.require(path, source: .of(environment: environment))
    } catch let error as UntrustedDeveloperDirectory {
        throw CLIError(errorDescription: error.failureMessage, reason: .xcodeUnusable, hint: error.hint)
    }
}

/// Another Xcode than the selected one, which just failed to load simulator support.
func suggestionInsteadOfSelectedXcode() -> XcodeSuggestion {
    guard let selected = try? FBXcodeDirectory.resolveDeveloperDirectory(), !selected.isEmpty else { return .current }
    return .instead(of: selected)
}

@MainActor
func performGlobalSetup(logger: OffsiderLogger) async throws {
    logger.info().log("Performing global setup...")

    // Check Xcode availability
    logger.info().log("Checking Xcode availability...")
    let xcodePath: String
    do {
        xcodePath = try FBXcodeDirectory.resolveDeveloperDirectory()
        if xcodePath.isEmpty {
            let errorMessage = XcodeSuggestion.current.adding(to: "Offsider could not find an active Xcode installation.")
            logger.error().log(errorMessage)
            throw CLIError(errorDescription: errorMessage, reason: .xcodeMissing, hint: XcodeSuggestion.current.select)
        }
        try requireTrustedDeveloperDirectory(xcodePath)
        logger.info().log("Xcode is available at: \(xcodePath)")
    } catch let error as CLIError {
        throw error
    } catch {
        let errorMessage = XcodeSuggestion.current.adding(to: "Offsider could not resolve the active Xcode installation: \(error.localizedDescription).")
        logger.error().log(errorMessage)
        throw CLIError(errorDescription: errorMessage, reason: .xcodeMissing, hint: XcodeSuggestion.current.select)
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
        let suggestion = XcodeSuggestion.instead(of: xcodePath)
        let errorMessage = suggestion.adding(to: "Offsider could not load simulator support from the selected Xcode installation: \(error.localizedDescription).")
        logger.error().log(errorMessage)
        throw CLIError(errorDescription: errorMessage, reason: .xcodeUnusable, hint: suggestion.select)
    }
    logger.info().log("Global setup complete.")
} 

@MainActor
func setup(logger: OffsiderLogger) async throws {
    // Check Xcode availability
    let developerDirectory: String
    do {
        developerDirectory = try FBXcodeDirectory.resolveDeveloperDirectory()
        if developerDirectory.isEmpty {
            logger.error().log("No active Xcode developer directory was found")
            throw CLIError(
                errorDescription: XcodeSuggestion.current.adding(to: "Offsider could not find an active Xcode installation."),
                reason: .xcodeMissing, hint: XcodeSuggestion.current.select
            )
        }
        try requireTrustedDeveloperDirectory(developerDirectory)
    } catch let error as CLIError {
        throw error
    } catch {
        logger.error().log("Failed to resolve the active Xcode installation: \(error.localizedDescription)")
        throw CLIError(
            errorDescription: XcodeSuggestion.current.adding(to: "Offsider could not find an active Xcode installation."),
            reason: .xcodeMissing, hint: XcodeSuggestion.current.select
        )
    }
    
    // Load essential frameworks
    do {
        try FBSimulatorControlFrameworkLoader.essentialFrameworks.loadPrivateFrameworks(logger)
    } catch {
        logger.error().log("Failed to load simulator support: \(error.localizedDescription)")
        let suggestion = XcodeSuggestion.instead(of: developerDirectory)
        throw CLIError(
            errorDescription: suggestion.adding(to: "Offsider could not load simulator support from the selected Xcode. Xcode 26 or later is needed."),
            reason: .xcodeUnusable, hint: suggestion.select
        )
    }
}
