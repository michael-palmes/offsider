import Foundation
import OffsiderAndroid
import OffsiderCore

/// Picks the backend from the device ID's shape: UUIDs are iOS simulators, emulator-NNNN and AVD names Android emulators.
@MainActor
enum DeviceRouter {
    struct Route {
        let backend: any DeviceBackend
        let device: DeviceID
    }

    static func allBackends(logger: OffsiderLogger, host: AndroidHost = .live()) -> [any DeviceBackend] {
        [IOSBackend(logger: logger), AndroidBackend.make(logger: logger, host: host)]
    }

    static func route(_ rawID: String, logger: OffsiderLogger, host: AndroidHost = .live()) async throws -> Route {
        let id = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
        switch DeviceIDClassifier.classify(rawID) {
        case .iosSimulator(let udid):
            return Route(backend: IOSBackend(logger: logger), device: DeviceID(rawValue: udid, platform: .ios))
        case .androidSerial(let port):
            // Existence is checked on first use, so a serial costs no adb round trip here.
            return Route(
                backend: AndroidBackend.make(logger: logger, host: host),
                device: DeviceID(rawValue: "emulator-\(port)", platform: .android)
            )
        case .androidAVDCandidate(let name):
            // Resolved now, so a typo gets "No device named X" before any work.
            let backend = AndroidBackend.make(logger: logger, host: host)
            let serial = try await backend.runningSerial(forAVDNamed: name)
            return Route(backend: backend, device: DeviceID(rawValue: serial, platform: .android))
        case .empty:
            throw CLIError(errorDescription: "Device ID cannot be empty. Run `offsider list-devices` to find device IDs.")
        case .unrecognised:
            throw CLIError(
                errorDescription: "Device \(id) is not an iOS simulator UDID. Run `offsider list-devices` to find device IDs."
            )
        }
    }
}
