import Foundation
import OffsiderCore

/// Android emulators over the adb server; lives for one command run, so its caches do too.
@MainActor
public final class AndroidBackend: DeviceBackend {
    let host: AndroidHost
    let log: AndroidLog
    private var sdk: AndroidSDK?
    private var client: AdbClient?
    private var geometries: [String: AndroidDisplayGeometry] = [:]
    private var avdNames: [String: String] = [:]

    public init(host: AndroidHost = .live(), log: @escaping AndroidLog) {
        self.host = host
        self.log = log
    }

    public var platform: DevicePlatform { .android }

    /// Locates the SDK and adb, and starts the adb server with `ADB_MDNS=0` when none answers. Idempotent.
    public func prepare() async throws {
        guard client == nil else { return }
        let sdk = try AndroidSDK.locate(host: host)
        let endpoint = try LoopbackEndpoint.adbServer(environment: host.environment)
        let client = AdbClient(endpoint: endpoint, connector: host.adbConnector)
        log(.debug, "Android SDK at \(sdk.root.path); adb server at \(endpoint)")
        try await AdbServerLauncher(adb: sdk.adb).ensureRunning(client: client, host: host)
        self.sdk = sdk
        self.client = client
    }

    public func listDevices() async throws -> [DeviceSummary] {
        try await directory().summaries()
    }

    /// State `device` with `sys.boot_completed`; the name is the AVD name, else the serial.
    public func requireBootedDevice(_ id: DeviceID) async throws -> BootedDevice {
        let serial = id.rawValue
        guard let emulator = try await directory().runningEmulator(serial: serial) else {
            throw AndroidError.serialNotRunning(serial)
        }
        switch emulator.state {
        case .device where emulator.bootCompleted:
            break
        case .device:
            throw AndroidError.stillBooting(serial, avd: emulator.avdName)
        case .offline:
            throw AndroidError.deviceOffline(serial, avd: emulator.avdName)
        case .unauthorized:
            throw AndroidError.deviceUnauthorised(serial, avd: emulator.avdName)
        case .other(let state):
            throw AndroidError.adbCommandFailed(serial: serial, command: "host:transport:\(serial)", detail: "adb reports the emulator as \(state)")
        }
        if let name = emulator.avdName {
            avdNames[serial] = name
        }
        return BootedDevice(id: id, name: emulator.avdName ?? serial)
    }

    /// For the router: the single running serial of an AVD; with no SDK, the name is simply unknown.
    public func runningSerial(forAVDNamed name: String) async throws -> String {
        do {
            try await prepare()
        } catch is PlatformUnavailable {
            throw AndroidError.noDeviceNamed(name)
        }
        return try await directory().serial(forAVDNamed: name)
    }

    public func accessibilityTree(for id: DeviceID, point: UIPoint?) async throws -> UITree {
        throw AndroidError.notSupported("describe-ui")
    }

    /// Logical size over scale, scale = density / 160, orientation from the viewport rotation.
    public func screenInfo(for id: DeviceID) async throws -> UIScreenInfo? {
        let geometry = try await geometry(for: id.rawValue)
        return UIScreenInfo(
            width: Self.dp(Double(geometry.logicalWidth) / geometry.scale),
            height: Self.dp(Double(geometry.logicalHeight) / geometry.scale),
            scale: geometry.scale,
            orientation: geometry.orientation
        )
    }

    /// dp to logical pixels in the current rotation, the space of uiautomator bounds and adb input; `tree` is unused.
    public func deviceCoordinates(
        for points: [(x: Double, y: Double)],
        tree: UITree?,
        on id: DeviceID
    ) async throws -> [(x: Double, y: Double)] {
        let scale = try await geometry(for: id.rawValue).scale
        return points.map { (x: $0.x * scale, y: $0.y * scale) }
    }

    public func openInputSession(for id: DeviceID) async throws -> any InputSession {
        throw AndroidError.notSupported("input")
    }

    public func sendDetachedTouch(_ steps: [DetachedTouchStep], to id: DeviceID) async throws {
        throw AndroidError.notSupported("touch")
    }

    public func screenshotPNG(for id: DeviceID) async throws -> Data {
        throw AndroidError.notSupported("screenshot")
    }

    func requireClient() throws -> AdbClient {
        guard let client else {
            throw AndroidError.adbServerNotRunning(endpoint: LoopbackEndpoint.defaultAdbServer.description)
        }
        return client
    }

    func directory() async throws -> AndroidDeviceDirectory {
        try await prepare()
        return AndroidDeviceDirectory(client: try requireClient(), host: host)
    }

    func geometry(for serial: String) async throws -> AndroidDisplayGeometry {
        if let cached = geometries[serial] {
            return cached
        }
        try await prepare()
        let result = try await requireClient().shell(AndroidDisplayGeometry.probeScript, on: serial)
        do {
            let geometry = try AndroidDisplayGeometry.parse(result.stdoutText)
            geometries[serial] = geometry
            return geometry
        } catch let error as AndroidDisplayGeometry.Unparseable {
            throw AndroidError.displayProbeUnparseable(serial, firstLine: error.firstLine)
        }
    }

    /// Rounded to 0.01 dp, as tree frames are.
    static func dp(_ value: Double) -> Double {
        (value * 100).rounded() / 100
    }
}
