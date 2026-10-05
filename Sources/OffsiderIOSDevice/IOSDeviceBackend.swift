import Foundation
import OffsiderCore

public enum IOSDeviceLogLevel: Sendable {
    case debug
    case info
    case warning
}

public typealias IOSDeviceLog = @Sendable (IOSDeviceLogLevel, String) -> Void

/// Physical iPhones and iPads named by UDID; lives for one command run, so its caches do too.
@MainActor
public final class IOSDeviceBackend: DeviceBackend {
    let host: IOSDeviceHost
    let log: IOSDeviceLog
    public let directory: IOSDeviceDirectory
    public var input = IOSDeviceInputHooks()
    let state = IOSDeviceState()
    private var xcode: XcodeLocation?
    private var woken: Set<String> = []

    public init(host: IOSDeviceHost = .live(), log: @escaping IOSDeviceLog) {
        self.host = host
        self.log = log
        directory = IOSDeviceDirectory(host: host)
    }

    public var platform: DevicePlatform { .ios }

    /// Finds the selected Xcode; without one, `list-devices` skips phones quietly. Idempotent.
    public func prepare() async throws {
        guard xcode == nil else { return }
        do {
            xcode = try await host.devicectl.locateXcode()
        } catch let error as IOSDeviceError where error.kind == .xcodeMissing {
            throw PlatformUnavailable(platform: .ios, message: error.message)
        }
    }

    public func listDevices() async throws -> [DeviceSummary] {
        try await prepare()
        return try await directory.summaries()
    }

    /// Wired, trusted, Developer Mode on and prepared; wakes the CoreDevice tunnel once when it is down.
    public func requireBootedDevice(_ id: DeviceID) async throws -> BootedDevice {
        try await prepare()
        guard let device = try await directory.device(udid: id.rawValue) else {
            throw IOSDeviceError.notListed(id.rawValue)
        }
        let name = DeviceName.display(device.udid, label: device.label)
        if let blocker = IOSDeviceReadiness.blocker(device, deviceSupportFinalized: directory.deviceSupportFinalized(device)) {
            throw Self.error(for: blocker, name: name, udid: device.udid)
        }
        if device.tunnelState != "connected" || device.ddiServicesAvailable != true, !woken.contains(device.udid) {
            log(.debug, "Waking the CoreDevice tunnel to \(name)")
            woken.insert(device.udid)
            try await directory.wake(udid: device.udid)
        }
        return BootedDevice(id: id, name: device.label)
    }

    static func error(for blocker: IOSDeviceReadiness, name: String, udid: String) -> IOSDeviceError {
        switch blocker {
        case .unavailable: return .unavailable(name)
        case .untrusted: return .untrusted(name)
        case .developerModeOff: return .developerModeOff(name)
        case .preparing, .reconnecting: return .preparing(name, udid: udid)
        case .wireless, .ready: return .notWired(name)
        }
    }

    public func accessibilityTree(for id: DeviceID, point: UIPoint?) async throws -> UITree {
        throw IOSDeviceError.notYetSupported(id.rawValue, feature: "Reading the accessibility tree")
    }

    /// The status bar and Dynamic Island, which change on their own.
    public func volatileScreenBands(for id: DeviceID) async -> ScreenBands {
        ScreenBands(top: 62, bottom: 0)
    }
}
