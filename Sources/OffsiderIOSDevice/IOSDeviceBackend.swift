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
    let log: IOSDeviceLog

    public init(log: @escaping IOSDeviceLog) {
        self.log = log
    }

    public var platform: DevicePlatform { .ios }

    public func prepare() async throws {}

    public func listDevices() async throws -> [DeviceSummary] { [] }

    public func requireBootedDevice(_ id: DeviceID) async throws -> BootedDevice {
        throw IOSDeviceError.notYetSupported(id.rawValue, feature: "Driving a device")
    }

    public func accessibilityTree(for id: DeviceID, point: UIPoint?) async throws -> UITree {
        throw IOSDeviceError.notYetSupported(id.rawValue, feature: "Reading the accessibility tree")
    }

    public func screenInfo(for id: DeviceID) async throws -> UIScreenInfo? { nil }

    public func deviceCoordinates(for points: [(x: Double, y: Double)], tree: UITree?, on id: DeviceID) async throws -> [(x: Double, y: Double)] {
        throw IOSDeviceError.notYetSupported(id.rawValue, feature: "Input")
    }

    public func openInputSession(for id: DeviceID) async throws -> any InputSession {
        throw IOSDeviceError.notYetSupported(id.rawValue, feature: "Input")
    }

    public func sendDetachedTouch(_ steps: [DetachedTouchStep], to id: DeviceID) async throws {
        throw IOSDeviceError.notYetSupported(id.rawValue, feature: "Input")
    }

    public func screenshotPNG(for id: DeviceID) async throws -> Data {
        throw IOSDeviceError.notYetSupported(id.rawValue, feature: "Taking a screenshot")
    }

    /// The status bar and Dynamic Island, which change on their own.
    public func volatileScreenBands(for id: DeviceID) async -> ScreenBands {
        ScreenBands(top: 62, bottom: 0)
    }
}
