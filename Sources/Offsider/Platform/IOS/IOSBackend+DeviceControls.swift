import FBSimulatorControl
import Foundation
import OffsiderCore

extension IOSBackend: DeviceSettingsControlling {
    func appearance(on id: DeviceID) async throws -> AppearanceReading {
        let simulator = try await simulator(for: id)
        return try await settingsCall("read the appearance of", id) {
            .fixed(try await simulator.currentAppearance() == .dark ? .dark : .light)
        }
    }

    func setAppearance(_ appearance: Appearance, on id: DeviceID) async throws {
        let simulator = try await simulator(for: id)
        try await settingsCall("set the appearance of", id) {
            try await simulator.setAppearance(appearance == .dark ? .dark : .light)
        }
    }

    func contentSize(on id: DeviceID) async throws -> ContentSizeReading {
        let simulator = try await simulator(for: id)
        let raw = try await settingsCall("read the content size of", id) {
            try await simulator.currentContentSizeCategory().rawValue
        }
        return try Self.contentSizeReading(iosIndex: raw, on: id)
    }

    /// The simulator's index as a category; an index outside 1 to 12 is an error, never a guess.
    static func contentSizeReading(iosIndex: Int, on id: DeviceID) throws -> ContentSizeReading {
        guard let category = ContentSizeCategory(iosIndex: iosIndex) else {
            throw CLIError(errorDescription: "Offsider could not read the content size of simulator \(id.rawValue): it reported \(iosIndex), which is not a known size. Set one with `offsider content-size large --device \(id.rawValue)`.")
        }
        return ContentSizeReading(category: category, fontScale: nil)
    }

    func setContentSize(_ category: ContentSizeCategory, on id: DeviceID) async throws {
        let simulator = try await simulator(for: id)
        guard let value = FBSimulatorContentSizeCategory(rawValue: category.iosIndex) else {
            throw CLIError(errorDescription: "Content size \(category.rawValue) has no simulator equivalent.")
        }
        try await settingsCall("set the content size of", id) {
            try await simulator.setContentSizeCategory(value)
        }
    }

    private func settingsCall<T>(_ action: String, _ id: DeviceID, _ body: () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch {
            logger.info().log("Settings call failed: \(error)")
            throw CLIError(errorDescription: "Offsider could not \(action) simulator \(id.rawValue): \(error.localizedDescription). Check it is booted with `offsider list-devices`.")
        }
    }
}

extension IOSBackend: DeviceShaking {
    func shake(_ id: DeviceID) async throws {
        try await sendOneEvent(.shake, to: id)
    }
}

extension IOSBackend: OrientationControlling {
    func orientation(of id: DeviceID) async throws -> DeviceOrientation? {
        let simulator = try await simulator(for: id)
        if displayCatalog.isFoldable(simulator),
           let active = await displayCatalog.activeDisplay(of: simulator, applicationFrame: applicationFrames[id.rawValue], refresh: true) {
            return await panelGeometry(on: active, of: simulator)?.deviceOrientation
        }
        return await SimulatorOrientationReader.currentOrientation(of: simulator, logger: logger)
            .map { DeviceOrientation(coordinateOrientation: $0.coreOrientation) }
    }

    func requestOrientation(_ orientation: DeviceOrientation, on id: DeviceID) async throws {
        guard let value = FBSimulatorHIDDeviceOrientation(rawValue: orientation.iosEventValue) else {
            throw CLIError(errorDescription: "Orientation \(orientation.rawValue) has no simulator event.")
        }
        displayCatalog.forgetReadings(of: id.rawValue)
        try await sendOneEvent(.deviceOrientation(value), to: id)
    }

    /// Outside `InputEvent`, so Android needs no stub for events it cannot send.
    private func sendOneEvent(_ event: FBSimulatorHIDEvent, to id: DeviceID) async throws {
        let session = try await HIDInteractor.makeSession(for: id.rawValue, logger: logger)
        do {
            try await HIDInteractor.performHIDEvent(event, in: session, logger: logger)
        } catch {
            await HIDInteractor.closeSession(session)
            throw error
        }
        await HIDInteractor.closeSession(session)
    }
}
