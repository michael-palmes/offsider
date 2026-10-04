import Foundation
import FBControlCore
import FBSimulatorControl
import OffsiderCore

// MARK: - HID Interactor


// On Xcode 27, dtuhidd silently drops events that reach it before its HID services open if the sender exits first.
// The pinned idb frameworks wait for dtuhidd to be ready, and closeSession drains before a one-shot command exits.
@MainActor
struct HIDInteractor {

    struct Session {
        let simulatorUDID: String
        let simulator: FBSimulator
        let hid: FBSimulatorHID
    }

    // Cache for HID connections per simulator
    private static var hidConnections: [String: FBSimulatorHID] = [:]
    static func stabilizationDelayMs(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> UInt64 {
        HIDStabilization.resolve(environment: environment).milliseconds
    }

    static func makeSession(for simulatorUDID: String, logger: OffsiderLogger) async throws -> Session {
        logger.info().log("Loading private frameworks for HID operations...")
        let frameworkLoader = FBSimulatorControlFrameworkLoader.xcodeFrameworks
        do {
            try frameworkLoader.loadPrivateFrameworks(logger)
            logger.info().log("Private frameworks loaded successfully.")
        } catch {
            logger.error().log("Failed to load private frameworks: \(error)")
            throw CLIError(
                errorDescription: "Offsider could not initialize simulator input using the selected Xcode installation. Confirm Xcode 26 or later is selected and try again.",
                reason: .xcodeUnusable, hint: "xcode-select -s <Xcode.app>/Contents/Developer"
            )
        }

        guard let simulator = try await cachedSimulator(udid: simulatorUDID, logger: logger) else {
            throw CLIError.deviceNotFound(id: simulatorUDID)
        }

        logger.info().log("Target (FBSimulator) obtained: \(simulator.udid)")
        logger.info().log("Simulator name: \(simulator.name)")

        guard simulator.state == .booted else {
            let stateDescription = FBiOSTargetStateStringFromState(simulator.state).rawValue
            throw CLIError.deviceNotBooted(id: simulatorUDID, state: stateDescription)
        }
        logger.info().log("Simulator state verified: booted")

        let bootIdentity = try HIDBroker.currentBootIdentity(simulatorUDID: simulatorUDID)
        let dtuhidProcessIdentifier = FBProcessFetcher().subprocess(
            of: bootIdentity.processIdentifier,
            withName: "dtuhidd"
        )
        let isDTUHIDSelected = HIDBroker.isDTUHIDSelected(
            processIdentifier: dtuhidProcessIdentifier
        )
        try await HIDBroker.waitForHIDReadiness(
            bootIdentity: bootIdentity,
            isDTUHIDSelected: isDTUHIDSelected,
            now: Date.init,
            sleep: { delay in try await Task.sleep(for: .seconds(delay)) }
        )
        let hid = try await getOrCreateHIDConnection(for: simulator, logger: logger)
        let connectedBootIdentity = try HIDBroker.currentBootIdentity(simulatorUDID: simulatorUDID)
        guard HIDBroker.shouldReuseSession(
            sessionBootIdentity: bootIdentity,
            currentBootIdentity: connectedBootIdentity
        ) else {
            hidConnections.removeValue(forKey: simulatorUDID)
            throw CLIError(
                errorDescription: "Simulator \(simulatorUDID) restarted while Offsider was connecting. Try the command again.",
                reason: .deviceRestarted
            )
        }
        try await HIDBroker.waitForHIDReadiness(
            bootIdentity: connectedBootIdentity,
            isDTUHIDSelected: hid.transportType == .dtuhid,
            now: Date.init,
            sleep: { delay in try await Task.sleep(for: .seconds(delay)) }
        )
        return Session(simulatorUDID: simulatorUDID, simulator: simulator, hid: hid)
    }

    static func performHIDEvent(_ event: FBSimulatorHIDEvent, in session: Session, logger: OffsiderLogger) async throws {
        logger.info().log("Performing HID event...")
        try await session.hid.send(event: event, logger: logger)
        logger.info().log("HID event performed successfully.")

        let delayMs = stabilizationDelayMs()
        if delayMs > 0 {
            logger.info().log("Applying stabilization delay of \(delayMs)ms...")
            try await Task.sleep(nanoseconds: delayMs * 1_000_000)
        }
    }

    static func closeSession(_ session: Session) async {
        hidConnections.removeValue(forKey: session.simulatorUDID)
        await session.hid.close()
    }

    static func compositeDragMovePoints(
        from start: (x: Double, y: Double),
        to end: (x: Double, y: Double),
        steps: Int
    ) throws -> [(x: Double, y: Double)] {
        try InputEvent.compositeDragMovePoints(from: start, to: end, steps: steps)
    }

    static func performPhysicalTap(
        at point: (x: Double, y: Double),
        preDelay: Double?,
        postDelay: Double?,
        in session: Session,
        logger: OffsiderLogger
    ) async throws {
        if let preDelay, preDelay > 0 {
            logger.info().log("Pre-delay: \(preDelay)s")
            try await Task.sleep(for: .seconds(preDelay))
        }

        let touchDownEvent = FBSimulatorHIDEvent.touch(direction: .down, x: point.x, y: point.y)
        let touchUpEvent = FBSimulatorHIDEvent.touch(direction: .up, x: point.x, y: point.y)
        var didTouchDown = false

        do {
            try await performHIDEvent(touchDownEvent, in: session, logger: logger)
            didTouchDown = true
            try await Task.sleep(for: .seconds(TapTiming.defaultHoldDuration))
            try await performHIDEvent(touchUpEvent, in: session, logger: logger)
            didTouchDown = false
        } catch {
            if didTouchDown {
                // Never replay touch-down after an ambiguous failure. A best-effort touch-up can
                // only release possible held state; it cannot produce a second tap by itself.
                try? await performHIDEvent(touchUpEvent, in: session, logger: logger)
            }
            throw error
        }

        if let postDelay, postDelay > 0 {
            logger.info().log("Post-delay: \(postDelay)s")
            try await Task.sleep(for: .seconds(postDelay))
        }
    }

    // Get or create a cached HID connection (matching CompanionLib's connectToHID behavior)
    private static func getOrCreateHIDConnection(for simulator: FBSimulator, logger: OffsiderLogger) async throws -> FBSimulatorHID {
        if let existingHID = hidConnections[simulator.udid] {
            logger.info().log("Using existing HID connection for simulator \(simulator.udid)")
            return existingHID
        }

        logger.info().log("Creating new HID connection for simulator \(simulator.udid)...")
        let hid = try await FBSimulatorHID(for: simulator)

        hidConnections[simulator.udid] = hid
        logger.info().log("HID connection created and cached for simulator \(simulator.udid)")

        return hid
    }

    static func clearHIDConnections() {
        hidConnections.removeAll()
    }
}
