import Foundation

/// Optional capability: an app's privacy permissions.
@MainActor
public protocol PermissionControlling: DeviceBackend {
    /// Every runtime permission the app requests; iOS simulators offer no read.
    func permissions(of app: String, on id: DeviceID) async throws -> AndroidPackagePermissions
    func applyPermission(_ action: PermissionAction, _ targets: [PermissionTarget], app: String, on id: DeviceID) async throws -> PermissionChange
}

/// Optional capability: a clean status bar for screenshots.
@MainActor
public protocol StatusBarControlling: DeviceBackend {
    func statusBar(on id: DeviceID) async throws -> StatusBarReading
    /// Returns the reading from before the override.
    func overrideStatusBar(_ override: StatusBarOverride, on id: DeviceID) async throws -> StatusBarReading
    func clearStatusBar(on id: DeviceID) async throws
}

/// Optional capability: biometric enrolment and sensor events.
@MainActor
public protocol BiometricControlling: DeviceBackend {
    /// Nil when the device cannot tell.
    func biometricEnrolled(on id: DeviceID) async throws -> Bool?
    func setBiometricEnrolment(_ enrolled: Bool, on id: DeviceID) async throws
    func defaultBiometricModality(on id: DeviceID) async throws -> BiometricModality
    /// Returns what was sent: the notification name on iOS, the console command on Android.
    func sendBiometric(_ outcome: BiometricOutcome, modality: BiometricModality, fingerID: Int?, on id: DeviceID) async throws -> String
}

/// Optional capability: the screen's power and lock state, stay awake, and waking the screen.
@MainActor
public protocol AwakeControlling: DeviceBackend {
    func awakeState(on id: DeviceID) async throws -> AwakeReading
    /// Stay awake on every power source, or off; returns the readings before and after.
    func setStayAwake(_ on: Bool, on id: DeviceID) async throws -> (previous: AwakeReading, current: AwakeReading)
    /// Turns the screen on and dismisses the lock screen, which a PIN, pattern or password leaves showing.
    func wake(on id: DeviceID) async throws -> WakeOutcome
    /// Types `code` once into the lock screen's focused PIN or password field, then Enter; returns the reading afterwards.
    func enterUnlockCode(_ code: UnlockCode, on id: DeviceID) async throws -> AwakeReading
    /// The model or AVD name already read for this device, without a round trip; nil when none was.
    func listedName(of id: DeviceID) -> String?
}

/// The JSON objects `permission`, `status-bar` and `biometric` print with `--json`, in schema order.
public enum DeviceStateReport {
    static func header(_ action: String, device: DeviceID) -> [(String, OrderedJSON)] {
        [("version", .integer(1)), ("action", .string(action)), ("device", .string(device.rawValue)), ("platform", .string(device.platform.rawValue))]
    }

    public static func permissionChange(_ change: PermissionChange, app: String, on device: DeviceID) -> String {
        let targets: [OrderedJSON] = change.targets.map { target in
            .object([
                ("service", .string(target.target)),
                ("permissions", .array(target.permissions.map { entry in
                    .object([
                        ("name", .string(entry.name)),
                        ("previous", .optional(entry.previous) { .string($0.rawValue) }),
                        ("current", .string(entry.current.rawValue)),
                        ("changed", .optional(entry.changed) { .bool($0) }),
                    ])
                })),
            ])
        }
        return OrderedJSON.object(header(change.action.rawValue, device: device) + [
            ("app", .string(app)),
            ("services", .array(targets)),
            ("appStopped", .bool(change.appStopped)),
            ("notes", .array(change.notes.map { .string($0) })),
        ]).rendered(compact: true)
    }

    public static func permissionShow(_ state: AndroidPackagePermissions, app: String, on device: DeviceID) -> String {
        OrderedJSON.object(header("show", device: device) + [
            ("app", .string(app)),
            ("permissions", .array(state.runtime.map { permission in
                .object([
                    ("name", .string(permission.name)),
                    ("state", .string(permission.granted ? "granted" : "denied")),
                    ("services", .array(PermissionService.allCases.filter { $0.androidPermissions?.contains(permission.name) == true }.map { .string($0.rawValue) })),
                ])
            })),
        ]).rendered(compact: true)
    }

    public static func services(_ services: [PermissionService]) -> String {
        OrderedJSON.object([
            ("version", .integer(1)),
            ("action", .string("services")),
            ("services", .array(services.map { service in
                .object([
                    ("service", .string(service.rawValue)),
                    ("ios", .optional(service.iosName) { .string($0) }),
                    ("android", .optional(service.androidPermissions) { .array($0.map { .string($0) }) }),
                ])
            })),
        ]).rendered(compact: true)
    }

    static func reading(_ reading: StatusBarReading?) -> OrderedJSON {
        .optional(reading) { reading in
            .object([
                ("overrides", .optional(reading.overrides) { overrides in .object(overrides.sorted { $0.key < $1.key }.map { ($0.key, .string($0.value)) }) }),
                ("demoAllowed", .optional(reading.demoAllowed) { .bool($0) }),
            ])
        }
    }

    public static func statusBar(_ action: String, override: StatusBarOverride?, current: StatusBarReading?, previous: StatusBarReading?, on device: DeviceID) -> String {
        let bar: OrderedJSON = .optional(override) { override in
            .object([
                ("time", .string(override.time)),
                ("batteryLevel", .integer(override.batteryLevel)),
                ("charging", .bool(override.charging)),
                ("wifiBars", .optional(override.wifiBars) { .integer($0) }),
                ("cellularBars", .optional(override.cellularBars) { .integer($0) }),
                ("operatorName", device.platform == .ios ? .string(override.operatorName) : .null),
                ("dataNetwork", .string(override.dataNetwork.rawValue)),
                ("notificationsHidden", device.platform == .android ? .bool(override.notificationsHidden) : .null),
            ])
        }
        return OrderedJSON.object(header(action, device: device) + [
            ("statusBar", bar),
            ("current", reading(current)),
            ("previous", reading(previous)),
        ]).rendered(compact: true)
    }

    public static func biometric(_ action: BiometricAction, modality: BiometricModality, enrolled: Bool?, sent: String?, on device: DeviceID) -> String {
        OrderedJSON.object(header(action.rawValue, device: device) + [
            ("modality", .string(modality.rawValue)),
            ("enrolled", .optional(enrolled) { .bool($0) }),
            ("sent", .optional(sent) { .string($0) }),
        ]).rendered(compact: true)
    }
}
