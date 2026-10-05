import Foundation

/// Whether Offsider can drive a listed iPhone or iPad, in the order the first problem is reported.
public enum IOSDeviceReadiness: String, Equatable, Sendable, CaseIterable {
    case unavailable
    case untrusted
    case developerModeOff
    case preparing
    /// Xcode prepared this OS before; the developer services return once the tunnel is up again.
    case reconnecting
    case wireless
    case ready

    public static func assess(_ device: DevicectlDevice, deviceSupportFinalized: Bool) -> IOSDeviceReadiness {
        if device.connectionState == "unavailable" || device.transportType == nil {
            return .unavailable
        }
        if device.pairingState != "paired" {
            return .untrusted
        }
        if device.developerModeStatus != "enabled" {
            return .developerModeOff
        }
        if device.ddiServicesAvailable == false {
            return deviceSupportFinalized ? .reconnecting : .preparing
        }
        if device.transportType == "localNetwork" {
            return .wireless
        }
        return .ready
    }

    /// The `list-devices` STATE column.
    public var stateText: String {
        switch self {
        case .ready: return "Booted"
        case .wireless: return "Wireless"
        case .untrusted: return "Untrusted"
        case .developerModeOff: return "Developer Mode off"
        case .preparing: return "Preparing"
        case .reconnecting: return "Reconnecting"
        case .unavailable: return "Unavailable"
        }
    }

    /// Xcode 26 writes `.finalized`, Xcode 27 `.processed_dyld_shared_cache_arm64e`, once a device's symbols are copied.
    static let deviceSupportMarkerNames = [".finalized", ".processed_dyld_shared_cache_arm64e"]

    /// The files whose presence means Xcode prepared this OS build before; empty without the build.
    public static func deviceSupportMarkers(for device: DevicectlDevice, home: URL) -> [String] {
        guard let productType = device.productType, let osVersion = device.osVersion, let build = device.osBuild else { return [] }
        let folder = home
            .appendingPathComponent("Library/Developer/Xcode/iOS DeviceSupport", isDirectory: true)
            .appendingPathComponent("\(productType) \(osVersion) (\(build))", isDirectory: true)
        return deviceSupportMarkerNames.map { folder.appendingPathComponent($0).path }
    }

    /// The first problem that stops a command, in readiness order, with Wi-Fi refused even while reconnecting.
    public static func blocker(_ device: DevicectlDevice, deviceSupportFinalized: Bool) -> IOSDeviceReadiness? {
        switch assess(device, deviceSupportFinalized: deviceSupportFinalized) {
        case .ready:
            return nil
        case .reconnecting:
            return device.transportType == "localNetwork" ? .wireless : nil
        case let problem:
            return problem
        }
    }
}
