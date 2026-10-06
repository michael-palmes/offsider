import Foundation
import OffsiderCore

public enum IOSDeviceLogLevel: Sendable {
    case debug
    case info
    /// A plain line on stderr, such as the first runner build.
    case notice
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
        installRunnerHooks()
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

    /// Wired, trusted, Developer Mode on and prepared, waking its tunnel or services once; a live broker vouches alone, as it exits once the device goes.
    public func requireBootedDevice(_ id: DeviceID) async throws -> BootedDevice {
        try await prepare()
        if let live = await liveSession(for: id) {
            return BootedDevice(id: id, name: live.status?.label ?? id.rawValue)
        }
        var device = try await listedDevice(id)
        let name = DeviceName.display(device.udid, label: device.label)
        var blocker = IOSDeviceReadiness.blocker(device, deviceSupportFinalized: directory.deviceSupportFinalized(device))
        if blocker == .preparing, device.transportType == "wired", !woken.contains(device.udid) {
            try await wake(device.udid, name: name)
            device = try await listedDevice(id)
            blocker = IOSDeviceReadiness.blocker(device, deviceSupportFinalized: directory.deviceSupportFinalized(device))
        }
        if let blocker {
            throw Self.error(for: blocker, name: name, udid: device.udid)
        }
        if device.tunnelState != "connected" || device.ddiServicesAvailable != true, !woken.contains(device.udid) {
            try await wake(device.udid, name: name)
        }
        return BootedDevice(id: id, name: device.label)
    }

    private func listedDevice(_ id: DeviceID) async throws -> DevicectlDevice {
        guard let device = try await directory.device(udid: id.rawValue) else {
            throw IOSDeviceError.notListed(id.rawValue)
        }
        return device
    }

    private func wake(_ udid: String, name: String) async throws {
        log(.debug, "Waking the CoreDevice tunnel to \(name)")
        woken.insert(udid)
        try await directory.wake(udid: udid)
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
        try await runnerTree(for: id, point: point)
    }

    /// Block colour drift between video frames of a still screen, well below what a caret or a glyph moves a block by.
    static let streamNoiseTolerance = 6

    /// The status bar, Dynamic Island and, while streaming, the screen-sharing indicator, along the UI's top edge in every orientation.
    public func volatileScreenBands(for id: DeviceID) async -> ScreenBands {
        guard let rotation = try? await geometry(for: id).screenInfo.rotation else {
            return ScreenBands(top: 62, bottom: 0, noiseTolerance: Self.streamNoiseTolerance)
        }
        return ScreenBands(
            top: 62, bottom: 0, everyOrientation: true, screenshotQuarterTurns: rotation.uprightQuarterTurnsCounterclockwise,
            noiseTolerance: Self.streamNoiseTolerance
        )
    }
}
