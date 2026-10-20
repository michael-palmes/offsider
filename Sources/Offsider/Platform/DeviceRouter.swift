import Foundation
import OffsiderAndroid
import OffsiderCore
import OffsiderIOSDevice

/// Picks the backend by ID shape (UUIDs simulators, iPhone UDIDs devices, the rest Android); `scope` closes each one when the command ends.
@MainActor
enum DeviceRouter {
    struct Route {
        let backend: any DeviceBackend
        let device: DeviceID
        /// The person's consent for a physical device; nil for simulators and emulators.
        var allowance: DeviceAllowance? = nil
    }

    static func allBackends(logger: OffsiderLogger, host: AndroidHost = .cli(), scope: CommandScope = .current) -> [any DeviceBackend] {
        [
            scope.adopt(IOSBackend(logger: logger)),
            scope.adopt(AndroidBackend.make(logger: logger, host: host)),
            scope.adopt(IOSDeviceBackend.make(logger: logger)),
        ]
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
        let route = try await resolve(rawID, logger: logger, host: host, scope: scope, gate: DevicePolicyGate.current)
        scope.noteRoute(route)
        return route
    }

    /// Gates a physical device: it must be named with `--device`, and the allow-list and managed policy must both allow it.
    static func requireAllowed(platform: DevicePlatform, key: String, rawID: String, gate: DevicePolicyGate, displayName: String? = nil) throws -> DeviceAllowance {
        let allowance = try gate.require(platform: platform, key: key, displayName: displayName)
        if let source = DeviceDefault.lastSource(for: rawID), source != .option {
            throw CLIError(
                errorDescription: "\(DeviceDefault.environmentKey) names the physical device \(key); a physical device must be named with --device on each command. Pass --device \(key).",
                reason: .usage,
                hint: "--device \(key)"
            )
        }
        return allowance
    }

    /// The phone's offsider.login.json package, read only when a phone allowed for any app needs one.
    @TaskLocal static var profilePackage: @Sendable () -> String? = { (try? LoginProfiles.load(project: nil, warn: { _ in }))??.package }

    /// Pinned apps within the managed ceiling; a phone allowed for any app drives only the app each command names, offsider.login.json's package by default.
    static func appScope(for allowance: DeviceAllowance, policy: PhysicalDevicePolicy, profilePackage: () -> String?) -> AndroidAppScope {
        let ceiling = policy.managed.allowedBundleIDs.map(Set.init)
        guard allowance.pinnedApps.isEmpty else {
            return AndroidAppScope(permitted: policy.permittedApps(for: allowance) ?? [], managedCeiling: ceiling)
        }
        return AndroidAppScope(permitted: [], managedCeiling: ceiling, needsTarget: true, target: profilePackage().flatMap { $0.isEmpty ? nil : $0 })
    }

    /// An `emulator-N` serial the adb server lists over USB is a phone in disguise; a list that cannot be read refuses too, so nothing reaches an unchecked device.
    nonisolated static func requireEmulator(_ serial: String, isUSBRow: (String) async throws -> Bool) async throws {
        let usb: Bool
        do {
            usb = try await isUSBRow(serial)
        } catch let error as PlatformUnavailable {
            throw error
        } catch let error as AndroidError where [.sdkVariableWithoutAdb, .nonLoopbackAdbServer, .invalidAdbServerSetting, .foreignAdbServer, .adbServerStartFailed].contains(error.kind) {
            throw error
        } catch {
            throw CLIError(
                errorDescription: "adb could not list devices, so Offsider cannot confirm \(serial) is an emulator and sent nothing to it. Start adb with `ADB_MDNS=0 adb start-server`, then retry.",
                reason: .deviceListFailed,
                hint: "ADB_MDNS=0 adb start-server"
            )
        }
        if usb {
            throw CLIError(
                errorDescription: "\(serial) is connected over USB: it is a physical device reporting an emulator's serial, so Offsider will not drive it. Nothing was sent to it.",
                reason: .deviceNotAllowed
            )
        }
    }

    private static func resolve(
        _ rawID: String,
        logger: OffsiderLogger,
        host: AndroidHost,
        scope: CommandScope,
        gate: DevicePolicyGate
    ) async throws -> Route {
        let id = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
        switch DeviceIDClassifier.classify(rawID) {
        case .iosSimulator(let udid):
            return Route(backend: scope.adopt(IOSBackend(logger: logger)), device: DeviceID(rawValue: udid, platform: .ios))
        case .iosDevice(let udid):
            // Gated before the backend exists; readiness is checked on first use, so routing costs no devicectl call.
            let allowance = try requireAllowed(platform: .ios, key: udid.uppercased(), rawID: rawID, gate: gate)
            let backend = scope.adopt(IOSDeviceBackend.make(logger: logger))
            IOSDevicePinning.configure(backend, allowance: allowance, policy: gate.policy())
            backend.runnerTeam = allowance.team
            return Route(backend: backend, device: DeviceID(rawValue: udid, platform: .ios), allowance: allowance)
        case .androidSerial(let port):
            let serial = "emulator-\(port)"
            let backend = scope.adopt(AndroidBackend.make(logger: logger, host: host))
            try await requireEmulator(serial, isUSBRow: { try await backend.isUSBRow(serial: $0) })
            return Route(backend: backend, device: DeviceID(rawValue: serial, platform: .android))
        case .androidNetworkSerial(let serial):
            throw AndroidError.networkDevice(serial)
        case .androidName(let name):
            // Resolved now, so a typo gets "No device named X" before any work.
            let backend = scope.adopt(AndroidBackend.make(logger: logger, host: host))
            let serial = try await backend.resolveAndroidName(name)
            let device = DeviceID(rawValue: serial, platform: .android)
            guard device.isPhysicalAndroidDevice else { return Route(backend: backend, device: device) }
            // Only the host-side device list has been read; nothing reaches the phone before this check.
            let allowance = try requireAllowed(platform: .android, key: serial, rawID: rawID, gate: gate)
            backend.appScopes[serial] = appScope(for: allowance, policy: gate.policy(), profilePackage: profilePackage)
            return Route(backend: backend, device: device, allowance: allowance)
        case .empty:
            throw CLIError(errorDescription: "Device ID cannot be empty. Run `offsider devices` to find device IDs.", reason: .invalidDeviceID, hint: "offsider devices")
        case .unrecognised:
            throw CLIError(
                errorDescription: "Device \(id) is not a device ID Offsider recognises. Run `offsider devices` to find device IDs.",
                reason: .invalidDeviceID, hint: "offsider devices"
            )
        }
    }
}
