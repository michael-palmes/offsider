import Foundation
import OffsiderCore

/// Picks the backend for a device ID; every ID routes to iOS for now.
@MainActor
enum DeviceRouter {
    struct Route {
        let backend: any DeviceBackend
        let device: DeviceID
    }

    static func allBackends(logger: OffsiderLogger) -> [any DeviceBackend] {
        [IOSBackend(logger: logger)]
    }

    static func route(_ rawID: String, logger: OffsiderLogger) async throws -> Route {
        Route(backend: IOSBackend(logger: logger), device: DeviceID(rawValue: rawID, platform: .ios))
    }
}
