import Foundation

/// A name for a device that survives restarts: an AVD name, a phone serial or an uppercased UDID. Emulator serials move between launches.
public enum StableDeviceKey {
    /// The key for a booted device; nil for an emulator whose AVD name is unknown.
    public static func of(_ booted: BootedDevice) -> String? {
        switch DeviceIDClassifier.classify(booted.id.rawValue) {
        case .androidSerial:
            return booted.name == booted.id.rawValue ? nil : booted.name
        case .iosSimulator(let udid), .iosDevice(let udid):
            return udid.uppercased()
        default:
            return booted.id.rawValue
        }
    }

    /// The key for an ID typed by the user, when it needs no device query: nil for an emulator serial or an invalid ID.
    public static func of(id raw: String) -> (platform: DevicePlatform, key: String)? {
        let id = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        switch DeviceIDClassifier.classify(id) {
        case .iosSimulator(let udid), .iosDevice(let udid):
            return (.ios, udid.uppercased())
        case .androidName(let name):
            return (.android, name)
        case .androidSerial, .androidNetworkSerial, .empty, .unrecognised:
            return nil
        }
    }

    /// The key for a `list-devices` row: a running emulator by its AVD.
    public static func of(_ row: DeviceSummary) -> String? {
        switch row.kind {
        case .emulator: return row.avd
        case .avd: return row.avd ?? row.id
        case .simulator: return row.id.uppercased()
        case .physical: return row.platform == .ios ? row.id.uppercased() : row.id
        }
    }
}
