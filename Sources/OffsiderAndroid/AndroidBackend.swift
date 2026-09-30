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
    private var dumpCounter = 0

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

    /// `uiautomator dump --compressed` mapped to dp; with `point`, the deepest node there as the only root.
    public func accessibilityTree(for id: DeviceID, point: UIPoint?) async throws -> UITree {
        let serial = id.rawValue
        let geometry = try await geometry(for: serial)
        dumpCounter += 1
        let script = UIAutomatorDump.script(path: UIAutomatorDump.devicePath(pid: getpid(), counter: dumpCounter))
        let result = try await requireClient().shell(script, on: serial, timeout: .seconds(20))

        let xml: String
        switch UIAutomatorDump.classify(result) {
        case .tree(let text): xml = text
        case .busy: throw AndroidError.uiautomatorBusy(serial)
        case .idleTimeout: throw AndroidError.uiautomatorIdle(serial)
        case .noWindow: throw AndroidError.uiautomatorNoWindow(serial)
        case .failed(let detail): throw AndroidError.uiautomatorFailed(serial, detail: detail)
        }
        let hierarchy: UIAutomatorHierarchy
        do {
            hierarchy = try UIAutomatorDump.parse(xml)
        } catch let error as UIAutomatorDump.ParseFailure {
            throw AndroidError.uiautomatorFailed(serial, detail: error.detail)
        }
        if let rotation = hierarchy.rotation {
            geometries[serial] = geometry.rotated(to: rotation)
        }

        let tree = UITree(platform: .android, device: serial, roots: AndroidTreeMapping.roots(from: hierarchy, scale: geometry.scale))
        guard let point else { return tree }
        return UITree(platform: .android, device: serial, roots: tree.deepestNode(at: point).map { [$0] } ?? [])
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
        let serial = id.rawValue
        let geometry = try await geometry(for: serial)
        return AndroidInputSession(
            device: id,
            executor: .adb(AdbDeviceShell(client: try requireClient(), serial: serial)),
            geometry: geometry,
            avdName: avdNames[serial],
            pasteUnavailableReason: pasteUnavailableReason(for: serial),
            log: log
        )
    }

    /// `touch --down` now and `touch --up` later: each call is one `input motionevent` script.
    public func sendDetachedTouch(_ steps: [DetachedTouchStep], to id: DeviceID) async throws {
        try await prepare()
        let inputSteps: [AndroidInputStep] = steps.map { step in
            switch step {
            case .down(let x, let y): return .touch(.down, AndroidPoint(x: x, y: y))
            case .up(let x, let y): return .touch(.up, AndroidPoint(x: x, y: y))
            case .hold(let seconds): return .pause(seconds)
            }
        }
        let shell = AdbDeviceShell(client: try requireClient(), serial: id.rawValue)
        for script in try AdbInputScript.scripts(for: inputSteps) {
            try await shell.run(script, waiting: AdbInputScript.waitTime(of: inputSteps))
        }
    }

    /// Finishes "and emulator-5556 ..." in the error for text that needs a paste.
    private func pasteUnavailableReason(for serial: String) -> String {
        let port = Int(serial.dropFirst("emulator-".count))
        let hasEndpoint = EmulatorDiscovery.live(host: host).contains { $0.consolePort == port && $0.grpcPort != nil }
        return hasEndpoint
            ? "has one, but this build sends input over adb only"
            : "has none (it was probably started with -port)"
    }

    /// `exec:screencap -p`: the guest's own PNG, already upright for its current rotation.
    public func screenshotPNG(for id: DeviceID) async throws -> Data {
        try await prepare()
        let png = try await requireClient().exec("screencap -p", on: id.rawValue, timeout: .seconds(15))
        guard png.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) else {
            let text = String(decoding: png.prefix(200), as: UTF8.self)
            let firstLine = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? "no output"
            throw AndroidError.adbCommandFailed(serial: id.rawValue, command: "screencap -p", detail: firstLine)
        }
        return png
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
            let stderrLine = result.stderrText.split(whereSeparator: \.isNewline).first.map(String.init)
            let detail = result.stdoutText.isEmpty ? stderrLine ?? error.firstLine : error.firstLine
            throw AndroidError.displayProbeUnparseable(serial, firstLine: detail)
        }
    }

    /// Rounded to 0.01 dp, as tree frames are.
    static func dp(_ value: Double) -> Double {
        (value * 100).rounded() / 100
    }
}
