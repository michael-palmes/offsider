import Foundation
import OffsiderAndroid
import OffsiderCore

/// Picks the backend from the device ID's shape; only iOS simulators are supported in this build.
@MainActor
enum DeviceRouter {
    struct Route {
        let backend: any DeviceBackend
        let device: DeviceID
    }

    static func allBackends(logger: OffsiderLogger, host: AndroidHost = .live()) -> [any DeviceBackend] {
        [IOSBackend(logger: logger), AndroidBackend.make(logger: logger, host: host)]
    }

    static func route(_ rawID: String, logger: OffsiderLogger) async throws -> Route {
        let id = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
        switch DeviceIDClassifier.classify(rawID) {
        case .iosSimulator(let udid):
            return Route(backend: IOSBackend(logger: logger), device: DeviceID(rawValue: udid, platform: .ios))
        case .androidSerial:
            throw androidNotSupported("Device \(id) is an Android emulator serial.")
        case .androidAVDCandidate:
            throw androidNotSupported("Device \(id) is not an iOS simulator UDID and looks like an Android emulator (AVD) name.")
        case .empty:
            throw CLIError(errorDescription: "Device ID cannot be empty. Run `offsider list-devices` to find device IDs.")
        case .unrecognised:
            throw CLIError(
                errorDescription: "Device \(id) is not an iOS simulator UDID. Run `offsider list-devices` to find device IDs."
            )
        }
    }

    private static func androidNotSupported(_ detail: String) -> CLIError {
        CLIError(
            errorDescription: "\(detail) Android emulators are not supported by this build yet. Use an iOS simulator UDID from `offsider list-devices`."
        )
    }
}
