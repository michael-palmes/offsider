import Foundation
import OffsiderCore

/// Android emulators over the adb server; lives for one command run, so its caches do too.
@MainActor
public final class AndroidBackend: DeviceBackend, AccessibilityActionPerforming, AccessibilityChangeWaiting {
    let host: AndroidHost
    let log: AndroidLog
    private var sdk: AndroidSDK?
    private var client: AdbClient?
    var geometries: [String: AndroidDisplayGeometry] = [:]
    /// Display 0's viewport `uniqueId` from the latest shell probe.
    var activeUniqueIds: [String: String] = [:]
    var knownDeviceStates: [String: [AndroidDeviceState.State]] = [:]
    var displayLists: [String: AndroidDisplayList] = [:]
    var screenStatuses: [String: (display: ScreenDisplay?, posture: Posture?)] = [:]
    private var avdNames: [String: String] = [:]
    private var transports: [String: AndroidTransport] = [:]
    private var warnedAboutOverride: Set<String> = []
    private var dumpCounter = 0
    var treeSources: [String: AndroidTreeSource] = [:]
    var announcedFallbacks: Set<String> = []
    var warnedAboutTruncation: Set<String> = []

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

    /// The helper's dump (else `uiautomator dump --compressed`) mapped to dp; with `point`, the deepest node there as the only root.
    public func accessibilityTree(for id: DeviceID, point: UIPoint?) async throws -> UITree {
        let serial = id.rawValue
        let roots: [UINode]
        switch try await treeSource(for: serial) {
        case .helper(let session):
            roots = try await helperRoots(serial, session: session)
        case .uiautomator:
            roots = try await uiautomatorRoots(serial)
        }
        let tree = UITree(platform: .android, device: serial, roots: roots)
        guard let point else { return tree }
        return UITree(platform: .android, device: serial, roots: tree.deepestNode(at: point).map { [$0] } ?? [])
    }

    private func uiautomatorRoots(_ serial: String) async throws -> [UINode] {
        let geometry = try await geometry(for: serial)
        let xml: String
        if let first = try await dumpHierarchy(serial) {
            xml = first
        } else {
            log(.debug, "uiautomator found no window on \(serial); reading the screen again")
            try await host.sleep(.milliseconds(500))
            guard let second = try await dumpHierarchy(serial) else {
                throw AndroidError.uiautomatorNoWindow(serial)
            }
            xml = second
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
        return AndroidTreeMapping.roots(from: hierarchy, scale: geometry.scale)
    }

    /// The hierarchy XML, or nil when uiautomator found no window, which lasts a moment while an activity starts.
    private func dumpHierarchy(_ serial: String) async throws -> String? {
        dumpCounter += 1
        let script = UIAutomatorDump.script(path: UIAutomatorDump.devicePath(pid: getpid(), counter: dumpCounter))
        let result = try await requireClient().shell(script, on: serial, timeout: .seconds(20), label: "uiautomator dump")
        switch UIAutomatorDump.classify(result) {
        case .tree(let text): return text
        case .noWindow: return nil
        case .busy: throw AndroidError.uiautomatorBusy(serial)
        case .idleTimeout: throw AndroidError.uiautomatorIdle(serial)
        case .failed(let detail): throw AndroidError.uiautomatorFailed(serial, detail: detail)
        }
    }

    /// Logical size over scale, scale = density / 160, orientation from the viewport rotation, and on a foldable its posture.
    public func screenInfo(for id: DeviceID) async throws -> UIScreenInfo? {
        let serial = id.rawValue
        var geometry = try await geometry(for: serial)
        var status = await screenStatus(serial)
        if (knownDeviceStates[serial]?.count ?? 0) >= 2 {
            let settled = try await settledGeometry(serial)
            if settled != geometry {
                geometry = settled
                screenStatuses[serial] = nil
                status = await screenStatus(serial)
            }
        }
        return UIScreenInfo(
            width: Self.dp(Double(geometry.logicalWidth) / geometry.scale),
            height: Self.dp(Double(geometry.logicalHeight) / geometry.scale),
            scale: geometry.scale,
            rotation: geometry.orientation,
            rotationDegrees: geometry.deviceOrientation.rotationDegrees,
            display: status.display,
            posture: status.posture
        )
    }

    /// The dp size from the display probe alone, without the display and posture reads `screenInfo` adds.
    public func screenSize(for id: DeviceID) async throws -> UISize? {
        let geometry = try await geometry(for: id.rawValue)
        return UISize(width: Self.dp(Double(geometry.logicalWidth) / geometry.scale), height: Self.dp(Double(geometry.logicalHeight) / geometry.scale))
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
        try await prepare()
        let shell = AdbDeviceShell(client: try requireClient(), serial: serial)
        return AndroidInputSession(
            device: id,
            shell: shell,
            route: { try await self.inputRoute(for: serial, shell: shell) },
            avdName: { await self.avdName(for: serial) },
            replaceFocusedText: { text in try await self.replaceFocusedText(text, on: serial) },
            sleep: host.sleep,
            log: log
        )
    }

    /// The display geometry (settled on a foldable), then the transport, when the session's first input needs them.
    private func inputRoute(for serial: String, shell: AdbDeviceShell) async throws -> AndroidInputRoute {
        let (executor, geometry) = try await inputExecutor(for: serial, shell: shell)
        switch try await transport(for: serial) {
        case .grpc(let emulator):
            return AndroidInputRoute(executor: executor, scale: geometry.scale, clipboard: emulator, adbReason: .forced)
        case .adb(let reason):
            return AndroidInputRoute(executor: executor, scale: geometry.scale, clipboard: nil, adbReason: reason)
        }
    }

    /// For messages: the cached name, else the live discovery file, else one `getprop` on this serial only.
    func avdName(for serial: String) async -> String? {
        if let cached = avdNames[serial] {
            return cached
        }
        let port = Int(serial.dropFirst("emulator-".count))
        let fromFile = EmulatorDiscovery.live(host: host).first { $0.consolePort == port }?.avdID
        let name: String?
        if let fromFile {
            name = fromFile
        } else {
            name = try? await directory().runningEmulator(serial: serial)?.avdName
        }
        avdNames[serial] = name
        return name
    }

    /// `touch --down` now and `touch --up` later: one gRPC finger (lifted by the emulator after 120 s if forgotten),
    /// or one `input motionevent` script per call over adb.
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
        if case .grpc(let driver) = try await inputExecutor(for: id.rawValue, shell: shell).executor {
            try await driver.run(inputSteps)
            return
        }
        for script in try AdbInputScript.scripts(for: inputSteps) {
            try await shell.run(script, waiting: AdbInputScript.waitTime(of: inputSteps))
        }
    }

    /// gRPC or adb for this serial, chosen once per command so a gesture never straddles both.
    func transport(for serial: String) async throws -> AndroidTransport {
        if let chosen = transports[serial] {
            return chosen
        }
        try await prepare()
        let chosen = try await EmulatorTransportSelector(host: host, log: log).choose(for: serial)
        transports[serial] = chosen
        return chosen
    }

    /// A resized display (`wm size` override) no longer maps onto the panel, so its input stays on adb; a foldable's gRPC waits for the panel's geometry.
    private func inputExecutor(for serial: String, shell: AdbDeviceShell) async throws -> (executor: AndroidInputExecutor, geometry: AndroidDisplayGeometry) {
        var geometry = try await geometry(for: serial)
        guard case .grpc(let emulator) = try await transport(for: serial) else {
            return (.adb(shell), geometry)
        }
        let posture = await postureIfFoldable(serial)
        if posture != nil {
            geometry = try await settledGeometry(serial)
        }
        guard !geometry.hasSizeOverride else {
            if warnedAboutOverride.insert(serial).inserted {
                log(.warning, "The display of \(serial) is resized (`wm size` reports an override), so its input goes over adb in this command.")
            }
            return (.adb(shell), geometry)
        }
        if let posture, posture != .open, posture != .halfOpened {
            log(.debug, "\(serial) is \(posture.rawValue), so its input goes over adb: gRPC touches land on the unfolded panel")
            return (.adb(shell), geometry)
        }
        return (.grpc(GrpcInputDriver(emulator: emulator, geometry: geometry, sleep: host.sleep)), geometry)
    }

    /// gRPC `getScreenshot`, turned upright when only the guest rotated; else adb's `screencap`.
    public func screenshotPNG(for id: DeviceID) async throws -> Data {
        try await prepare()
        let serial = id.rawValue
        guard case .grpc(let emulator) = try await transport(for: serial) else {
            return try await adbScreenshot(serial)
        }
        let geometry = try await geometry(for: serial)
        let frame = try await emulator.screenshot(.png, fitting: nil)
        do {
            return try AndroidScreenCapture.png(from: frame, guestRotation: geometry.rotation)
        } catch let failure as AndroidScreenCapture.ImageFailure {
            throw AndroidError.screenshotFailed(serial, detail: failure.detail)
        }
    }

    /// The bars the running helper measured in its latest window list; 60 and 48 dp when no helper runs.
    public func volatileScreenBands(for id: DeviceID) async -> ScreenBands {
        guard let session = runningHelper(for: id.rawValue), let display = session.display else {
            return SystemBars.fallback
        }
        let bands = SystemBars.bands(windows: session.windows, display: display)
        log(.debug, "System bars on \(id.rawValue) from the helper's windows: top \(bands.top) dp, bottom \(bands.bottom) dp")
        return bands
    }

    /// `exec:screencap -p`: the guest's own PNG, already upright for its current rotation; `-d` picks a physical display.
    func adbScreenshot(_ serial: String, physicalDisplay: String? = nil) async throws -> Data {
        let command = physicalDisplay.map { "screencap -d \($0) -p" } ?? "screencap -p"
        let png = try await requireClient().exec(command, on: serial, timeout: .seconds(15))
        guard png.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) else {
            let text = String(decoding: png.prefix(200), as: UTF8.self)
            let firstLine = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? "no output"
            throw AndroidError.adbCommandFailed(serial: serial, command: command, detail: firstLine)
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
        if let measured = try await helperGeometry(serial) {
            geometries[serial] = measured
            return measured
        }
        try await prepare()
        let result = try await requireClient().shell(AndroidDisplayGeometry.probeScript, on: serial, label: "wm size; wm density; dumpsys input")
        do {
            let geometry = try AndroidDisplayGeometry.parse(result.stdoutText)
            geometries[serial] = geometry
            activeUniqueIds[serial] = AndroidDisplayGeometry.viewportUniqueId(in: result.stdoutText)
            return geometry
        } catch let error as AndroidDisplayGeometry.Unparseable {
            let stderrLine = result.stderrText.split(whereSeparator: \.isNewline).first.map(String.init)
            let detail = result.stdoutText.isEmpty ? stderrLine ?? error.firstLine : error.firstLine
            throw AndroidError.displayProbeUnparseable(serial, firstLine: detail)
        }
    }

    /// Stops helpers first (freeing the UiAutomation slot), then gRPC clients and their keys; a second call does nothing.
    public func close() async {
        let helpers = treeSources.sorted { $0.key < $1.key }.compactMap { _, source -> HelperSession? in
            guard case .helper(let session) = source else { return nil }
            return session
        }
        let open = transports.sorted { $0.key < $1.key }.map(\.value)
        treeSources = [:]
        announcedFallbacks = []
        warnedAboutTruncation = []
        transports = [:]
        geometries = [:]
        activeUniqueIds = [:]
        knownDeviceStates = [:]
        displayLists = [:]
        screenStatuses = [:]
        avdNames = [:]
        warnedAboutOverride = []
        for helper in helpers {
            await helper.close()
        }
        for transport in open {
            if case .grpc(let emulator) = transport {
                await emulator.close()
            }
        }
    }

    /// Rounded to 0.01 dp, as tree frames are.
    static func dp(_ value: Double) -> Double {
        (value * 100).rounded() / 100
    }
}
