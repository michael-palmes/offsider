import Foundation
import OffsiderAndroid
import OffsiderCore

/// Picks the backend from the device ID's shape: UUIDs are iOS simulators; emulator-NNNN, AVD names and USB phone serials Android.
/// Every backend it builds is adopted by `scope`, which closes it when the command ends.
@MainActor
enum DeviceRouter {
    struct Route {
        let backend: any DeviceBackend
        let device: DeviceID
    }

    static func allBackends(logger: OffsiderLogger, host: AndroidHost = .cli(), scope: CommandScope = .current) -> [any DeviceBackend] {
        [scope.adopt(IOSBackend(logger: logger)), scope.adopt(AndroidBackend.make(logger: logger, host: host))]
    }

    /// Routes, then locks the device for this command before any input session or helper starts.
    static func routeForInput(
        _ option: DeviceOption,
        logger: OffsiderLogger,
        locking: Bool = true,
        host: AndroidHost = .cli(),
        scope: CommandScope = .current,
        claims: DeviceClaims = .current
    ) async throws -> Route {
        try await routeForInput(option.id, logger: logger, locking: locking, host: host, scope: scope, claims: claims)
    }

    static func routeForInput(
        _ rawID: String,
        logger: OffsiderLogger,
        locking: Bool = true,
        host: AndroidHost = .cli(),
        scope: CommandScope = .current,
        claims: DeviceClaims = .current
    ) async throws -> Route {
        let route = try await route(rawID, logger: logger, host: host, scope: scope)
        if locking {
            try await claims.claim(route.device)
        }
        return route
    }

    /// Routes under `watchdog`'s setup bound, then locks with it disarmed, so a `--wait-lock` wait is never taken for a hung device.
    static func routeForInput(
        _ rawID: String,
        logger: OffsiderLogger,
        watchdog: DeviceWatchdog,
        locking: Bool = true,
        host: AndroidHost = .cli(),
        scope: CommandScope = .current,
        claims: DeviceClaims = .current
    ) async throws -> Route {
        let route = try await watchdog.guardingSetup(device: rawID) {
            try await route(rawID, logger: logger, host: host, scope: scope)
        }
        if locking {
            try await claims.claim(route.device)
        }
        return route
    }

    static func route(
        _ rawID: String,
        logger: OffsiderLogger,
        host: AndroidHost = .cli(),
        scope: CommandScope = .current
    ) async throws -> Route {
        let route = try await resolve(rawID, logger: logger, host: host, scope: scope)
        scope.noteRoute(route)
        return route
    }

    private static func resolve(
        _ rawID: String,
        logger: OffsiderLogger,
        host: AndroidHost,
        scope: CommandScope
    ) async throws -> Route {
        let id = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
        switch DeviceIDClassifier.classify(rawID) {
        case .iosSimulator(let udid):
            return Route(backend: scope.adopt(IOSBackend(logger: logger)), device: DeviceID(rawValue: udid, platform: .ios))
        case .androidSerial(let port):
            // Existence is checked on first use, so a serial costs no adb round trip here.
            return Route(
                backend: scope.adopt(AndroidBackend.make(logger: logger, host: host)),
                device: DeviceID(rawValue: "emulator-\(port)", platform: .android)
            )
        case .androidNetworkSerial(let serial):
            throw AndroidError.networkDevice(serial)
        case .androidName(let name):
            // Resolved now, so a typo gets "No device named X" before any work.
            let backend = scope.adopt(AndroidBackend.make(logger: logger, host: host))
            let serial = try await backend.resolveAndroidName(name)
            return Route(backend: backend, device: DeviceID(rawValue: serial, platform: .android))
        case .empty:
            throw CLIError(errorDescription: "Device ID cannot be empty. Run `offsider list-devices` to find device IDs.", reason: .invalidDeviceID, hint: "offsider list-devices")
        case .unrecognised:
            throw CLIError(
                errorDescription: "Device \(id) is not an iOS simulator UDID. Run `offsider list-devices` to find device IDs.",
                reason: .invalidDeviceID, hint: "offsider list-devices"
            )
        }
    }
}
