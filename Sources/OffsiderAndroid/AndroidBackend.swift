import Foundation
import OffsiderCore

/// Android emulators and USB phones over the adb server; lives for one command run, so its caches do too.
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
    /// How each device with several displays answers `screencap` without `-d`, learnt from this command's first capture.
    var screencapPicks: [String: ScreencapPick] = [:]
    var screenStatuses: [String: (display: ScreenDisplay?, posture: Posture?)] = [:]
    /// Screen status reads under way, shared by every caller; the ticket keeps a read started before `forgetDisplay` from landing after it.
    var statusTasks: [String: Task<(display: ScreenDisplay?, posture: Posture?), Never>] = [:]
    var statusTickets: [String: Int] = [:]
    var statusTicket = 0
    /// The latest `cmd device_state state` of each device, from a status read.
    var stateReadings: [String: AndroidDeviceState.Reading] = [:]
    /// The active panel the display cache named and this command's capture confirmed.
    var cachedDisplayIds: [String: String] = [:]
    private var avdNames: [String: String] = [:]
    /// Phones this command named, from their device-list row, once checked.
    var phones: [String: ConnectedPhone] = [:]
    /// The row routing read for a phone, so `requireConnectedPhone` checks it without listing again.
    private var listedPhones: [String: ConnectedPhone] = [:]
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
        let (sdk, client) = try await host.timing.measure(.prepare) {
            let sdk = try AndroidSDK.locate(host: host)
            let endpoint = try LoopbackEndpoint.adbServer(environment: host.environment)
            let client = AdbClient(endpoint: endpoint, connector: host.adbConnector, timing: host.timing)
            log(.debug, "Android SDK at \(sdk.root.path); adb server at \(endpoint)")
            try await AdbServerLauncher(adb: sdk.adb).ensureRunning(client: client, host: host)
            return (sdk, client)
        }
        self.sdk = sdk
        self.client = client
    }

    /// The SDK's adb, for the emulator console commands the adb server protocol does not carry.
    func adbExecutable() async throws -> URL {
        try await prepare()
        guard let sdk else { throw PlatformUnavailable(platform: .android, message: "The Android SDK was not found.") }
        return sdk.adb
    }

    public func listDevices() async throws -> [DeviceSummary] {
        try await directory().summaries()
    }

    /// State `device` with `sys.boot_completed`; the name is the AVD name, else the serial. A phone needs state `device`.
    public func requireBootedDevice(_ id: DeviceID) async throws -> BootedDevice {
        let serial = id.rawValue
        guard case .androidSerial = DeviceIDClassifier.classify(serial) else {
            let phone = try await requireConnectedPhone(serial)
            return BootedDevice(id: id, name: phone.model ?? serial)
        }
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

    /// The model or AVD name an earlier `requireBootedDevice` read for this device, without asking adb again.
    public func listedName(of id: DeviceID) -> String? {
        phones[id.rawValue]?.model ?? avdNames[id.rawValue]
    }

    /// The USB phone's row for a serial the user named; offline, unauthorised and network rows are refused.
    func requireConnectedPhone(_ serial: String) async throws -> ConnectedPhone {
        if let cached = phones[serial] {
            return cached
        }
        let listed: ConnectedPhone?
        if let row = listedPhones[serial] {
            listed = row
        } else {
            listed = try await directory().connectedPhone(serial: serial)
        }
        guard let phone = listed else {
            throw AndroidError.phoneNotConnected(serial)
        }
        guard phone.kind == .usb else { throw AndroidError.networkDevice(serial) }
        switch phone.state {
        case .device: break
        case .offline: throw AndroidError.phoneOffline(serial)
        case .unauthorized: throw AndroidError.phoneUnauthorised(serial)
        case .other(let state):
            throw AndroidError.adbCommandFailed(serial: serial, command: "host:transport:\(serial)", detail: "adb reports the phone as \(state)")
        }
        phones[serial] = phone
        return phone
    }

    /// For the router: a USB phone by exact serial, else an AVD's single running serial; unknown with no SDK.
    public func resolveAndroidName(_ name: String) async throws -> String {
        do {
            try await prepare()
        } catch is PlatformUnavailable {
            throw AndroidError.noDeviceNamed(name)
        }
        let resolved = try await directory().resolveListing(name: name)
        if let phone = resolved.phone {
            listedPhones[phone.serial] = phone
        }
        return resolved.serial
    }

    /// The helper's dump (else `uiautomator dump --compressed`) mapped to dp; with `point`, the deepest node there as the only root.
    public func accessibilityTree(for id: DeviceID, point: UIPoint?) async throws -> UITree {
        let serial = id.rawValue
        let startedAt = Date()
        let roots: [UINode]
        var truncated = false
        var windows: [UIWindowInfo]?
        switch try await treeSource(for: serial) {
        case .helper(let session):
            let read = try await helperRoots(serial, session: session)
            (roots, truncated, windows) = (read.roots, read.truncated, read.windows)
        case .uiautomator:
            roots = try await uiautomatorRoots(serial)
        }
        var tree = UITree(platform: .android, device: serial, roots: roots)
        tree.sourceTruncated = truncated
        tree.windows = windows
        guard let point else {
            DeviceActivityLedger.current.recordTreeRead(tree, on: id, startedAt: startedAt)
            return tree
        }
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
        // Status first: with the geometry unknown it reads the probe in the same shell call.
        var status = await screenStatus(serial)
        // Mid-fold both panels are dark for a moment; the display is named only once one lights.
        for _ in 0..<Self.darkPanelReads where status.display == nil && displayLists[serial]?.panelsDark == true {
            try await host.sleep(.milliseconds(250))
            forgetDisplay(of: serial)
            status = await screenStatus(serial)
        }
        var geometry = try await geometry(for: serial)
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
            focusedSecureField: { await self.hasFocusedSecureField(id) },
            multiTouchHelper: { try await self.multiTouchHelper(serial) },
            readFocusedField: { await self.focusedFieldReading(serial) },
            pasteFocused: { field in try await self.pasteIntoFocusedField(serial, expecting: field) },
            sleep: host.sleep,
            log: log,
            timing: host.timing
        )
    }

    /// The helper for a multi-finger touch on an `input` route, unless OFFSIDER_ANDROID_INPUT=input forbids it.
    private func multiTouchHelper(_ serial: String) async throws -> HelperInputDriver? {
        guard try AndroidInputPolicy.policy(host: host) != .input else { return nil }
        return try await helperForInput(serial, required: false).map { HelperInputDriver(session: $0) }
    }

    /// Best effort: an unreadable screen does not block typing, since the guard only keeps a password off the clipboard.
    private func hasFocusedSecureField(_ id: DeviceID) async -> Bool {
        let serial = id.rawValue
        do {
            let roots: [UINode]
            switch try await treeSource(for: serial, announcingFallback: false) {
            case .helper(let session): roots = try await helperRoots(serial, session: session).roots
            case .uiautomator: roots = try await uiautomatorRoots(serial)
            }
            return UITree(platform: .android, device: serial, roots: roots).secureFocus == .secureFocused
        } catch {
            log(.debug, "Could not check for a focused password field on \(id.rawValue) before pasting: \((error as? AndroidError)?.message ?? error.localizedDescription)")
            return false
        }
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
        guard case .androidSerial(let port) = DeviceIDClassifier.classify(serial) else { return nil }
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
        if case .grpc(let driver) = try await inputExecutor(for: id.rawValue, shell: shell, allowingHelper: false).executor {
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
    private func inputExecutor(
        for serial: String,
        shell: AdbDeviceShell,
        allowingHelper: Bool = true
    ) async throws -> (executor: AndroidInputExecutor, geometry: AndroidDisplayGeometry) {
        let policy = try AndroidInputPolicy.policy(host: host)
        var geometry = try await geometry(for: serial)
        guard case .grpc(let emulator) = try await transport(for: serial) else {
            return (allowingHelper ? try await shellExecutor(serial, shell: shell, policy: policy) : .adb(shell), geometry)
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

    /// Without gRPC: the helper when forced or already running for this command, else `input` shell commands.
    private func shellExecutor(_ serial: String, shell: AdbDeviceShell, policy: AndroidInputPolicy) async throws -> AndroidInputExecutor {
        let session: HelperSession?
        switch policy {
        case .input: session = nil
        case .auto: session = runningHelper(for: serial)
        case .helper: session = try await helperForInput(serial, required: true)
        }
        return session.map { .helper(HelperInputDriver(session: $0)) } ?? .adb(shell)
    }

    /// gRPC `getScreenshot`, turned upright when only the guest rotated; else adb's `screencap`.
    public func screenshotPNG(for id: DeviceID) async throws -> Data {
        try await prepare()
        return try await host.timing.measure(.capture) {
            try await capturePNG(id.rawValue)
        }
    }

    private func capturePNG(_ serial: String) async throws -> Data {
        let policy = try AndroidCapturePolicy.policy(host: host)
        guard case .grpc(let emulator) = try await transport(for: serial) else {
            return try await shellCapture(serial, policy: policy)
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

    /// Without gRPC: the device's PNG, or raw pixels from screencap or the helper encoded here; those two fall back to the PNG.
    private func shellCapture(_ serial: String, policy: AndroidCapturePolicy) async throws -> Data {
        let pixels: AndroidScreenCapture.Pixels
        switch policy {
        case .auto, .screencap:
            return try await adbScreenshot(serial)
        case .raw:
            let capture = try await activeScreencap(serial, format: nil) { output in
                (try? AndroidScreenCapture.rawHeader(output)).map { ($0.width, $0.height) }
            }
            do {
                pixels = try AndroidScreenCapture.pixels(fromScreencapRaw: capture.output)
            } catch let failure as AndroidScreenCapture.ImageFailure {
                log(.debug, "Raw screencap on \(serial) was unreadable (\(failure.detail)); using `screencap -p`")
                return try await adbScreenshot(serial)
            }
        case .helper:
            guard let captured = try await helperPixels(serial) else {
                return try await adbScreenshot(serial)
            }
            pixels = captured
        }
        do {
            return try host.timing.measure(.captureEncode) { try AndroidScreenCapture.encodePNG(pixels) }
        } catch let failure as AndroidScreenCapture.ImageFailure {
            throw AndroidError.screenshotFailed(serial, detail: failure.detail)
        }
    }

    /// The helper's raw screenshot, starting the helper if needed; nil, with a warning, when it cannot serve.
    private func helperPixels(_ serial: String) async throws -> AndroidScreenCapture.Pixels? {
        let problem: String
        do {
            if let session = try await helperForInput(serial, required: false) {
                return try await session.screenshot()
            }
            problem = "the helper is unavailable"
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as HelperErrorBody {
            problem = "\(error.code): \(error.message)"
        } catch let error as HelperProtocolError {
            problem = error.detail
        } catch let error as AndroidError {
            problem = error.message
        } catch {
            problem = String(describing: error)
        }
        log(.warning, "The UiAutomation helper could not take a screenshot on \(serial) (\(problem)), so Offsider used `screencap -p`.")
        return nil
    }

    /// `exec:screencap -p`: the guest's upright PNG from the display `-d` picks, else the active one, skipping a warning printed before it.
    func adbScreenshot(_ serial: String, physicalDisplay: String? = nil) async throws -> Data {
        let capture = if let physicalDisplay {
            try await screencap(serial, format: "-p", display: physicalDisplay)
        } else {
            try await activeScreencap(serial, format: "-p") { AndroidScreenCapture.png(fromScreencap: $0).flatMap(AndroidScreenCapture.pngSize) }
        }
        guard let png = AndroidScreenCapture.png(fromScreencap: capture.output) else {
            throw AndroidError.adbCommandFailed(serial: serial, command: capture.command, detail: AndroidScreenCapture.failureDetail(capture.output))
        }
        return png
    }

    /// `screencap` of the active display: the cached panel while it holds, else plain while its pick has the active size, else `-d`.
    private func activeScreencap(
        _ serial: String,
        format: String?,
        size: (Data) -> (width: Int, height: Int)?
    ) async throws -> (output: Data, command: String) {
        if screencapPicks[serial] == .namedDisplay, let display = knownActiveDisplayId(serial) {
            return try await screencap(serial, format: format, display: display)
        }
        if screencapPicks[serial] == nil, let cached = await cachedScreencap(serial, format: format, size: size) {
            return cached
        }
        let capture = try await screencap(serial, format: format, display: nil)
        guard AndroidScreenCapture.warnsOfSeveralDisplays(capture.output) else { return capture }
        let picked = size(capture.output)
        if await hasActiveDisplaySize(picked, serial) {
            screencapPicks[serial] = .activeDisplay
            rememberDisplay(serial, size: picked)
            return capture
        }
        if screencapPicks[serial] == .activeDisplay {
            log(.debug, "screencap on \(serial) no longer has the active display's size; reading the displays again after a fold")
            forgetDisplay(of: serial)
            if await hasActiveDisplaySize(picked, serial) {
                rememberDisplay(serial, size: picked)
                return capture
            }
        }
        if knownActiveDisplayId(serial) == nil {
            _ = await screenStatus(serial)
        }
        guard let display = knownActiveDisplayId(serial) else {
            log(.debug, "screencap on \(serial) picked a display Offsider cannot check against the active one; keeping it")
            return capture
        }
        log(.debug, "screencap on \(serial) did not pick the active display; capturing \(display) with -d")
        screencapPicks[serial] = .namedDisplay
        let named = try await screencap(serial, format: format, display: display)
        rememberDisplay(serial, size: size(named.output))
        return named
    }

    /// The display cache for this host, or nil when it is off.
    private func displayCache() -> AndroidDisplayCache? {
        host.displayCacheDirectory().map(AndroidDisplayCache.init(directory:))
    }

    /// The cached panel's capture, with `cmd device_state state` alongside; nil, dropping the entry, unless connection, state and size match.
    private func cachedScreencap(
        _ serial: String,
        format: String?,
        size: (Data) -> (width: Int, height: Int)?
    ) async -> (output: Data, command: String)? {
        guard let cache = displayCache(), let entry = cache.load(serial: serial) else { return nil }
        guard let transport = (phones[serial] ?? listedPhones[serial])?.transportId, entry.transportId == transport else {
            log(.debug, "The display cache of \(serial) was learnt on another adb connection; reading the displays again")
            cache.remove(serial: serial)
            return nil
        }
        async let capturing = try? screencap(serial, format: format, display: entry.displayId)
        async let reading = entry.committed == nil ? nil : try? deviceStateReading(serial)
        let (capture, state) = await (capturing, reading)
        let captured = capture.flatMap { size($0.output) }
        guard let capture, let captured, captured.width == entry.width, captured.height == entry.height,
              entry.committed == nil || state?.committed == entry.committed else {
            log(.debug, "The display cache of \(serial) no longer matches its panel, posture or size; reading the displays again")
            cache.remove(serial: serial)
            return nil
        }
        screencapPicks[serial] = .namedDisplay
        cachedDisplayIds[serial] = entry.displayId
        if !entry.states.isEmpty {
            knownDeviceStates[serial] = knownDeviceStates[serial] ?? entry.states
        }
        if let state {
            stateReadings[serial] = state
        }
        if screenStatuses[serial] == nil, entry.states.count >= 2 {
            screenStatuses[serial] = (ScreenDisplay(id: entry.role, platformId: entry.displayId), state?.committed.posture)
        }
        return capture
    }

    /// Keeps what this capture confirmed for the next command: the active panel, its size and the device state.
    private func rememberDisplay(_ serial: String, size: (width: Int, height: Int)?) {
        guard let size, let cache = displayCache(), let transport = (phones[serial] ?? listedPhones[serial])?.transportId,
              let list = displayLists[serial], let active = activeDisplay(in: list, serial: serial),
              AndroidDisplayCacheEntry.isDisplayId(active.descriptor.platformId) else {
            return
        }
        cache.save(AndroidDisplayCacheEntry(
            serial: serial, transportId: transport, displayId: active.descriptor.platformId, role: active.descriptor.role.rawValue,
            states: knownDeviceStates[serial] ?? [], committed: stateReadings[serial]?.committed, width: size.width, height: size.height
        ))
    }

    private func screencap(_ serial: String, format: String?, display: String?) async throws -> (output: Data, command: String) {
        let command = (["screencap"] + (display.map { ["-d", $0] } ?? []) + (format.map { [$0] } ?? [])).joined(separator: " ")
        return (try await requireClient().exec(command, on: serial, timeout: .seconds(15)), command)
    }

    /// The active capture has logical display 0's settled size, either way round; the screen status read first is the one `screenInfo` reuses.
    private func hasActiveDisplaySize(_ size: (width: Int, height: Int)?, _ serial: String) async -> Bool {
        guard let size else { return false }
        _ = await screenStatus(serial)
        guard let geometry = try? await settledGeometry(serial) else { return false }
        return [size.width, size.height].sorted() == [geometry.logicalWidth, geometry.logicalHeight].sorted()
    }

    static let darkPanelReads = 8

    /// The active display's platform id from this command's display list or display probe; nil when neither has read it, or every panel is dark.
    func knownActiveDisplayId(_ serial: String) -> String? {
        guard displayLists[serial]?.panelsDark != true else { return nil }
        return displayLists[serial].flatMap { activeDisplay(in: $0, serial: serial) }?.descriptor.platformId ?? cachedDisplayIds[serial] ?? viewportPlatformId(serial)
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
        if let pending = statusTasks[serial] {
            _ = await pending.value
            if let cached = geometries[serial] {
                return cached
            }
        }
        if let measured = try await helperGeometry(serial) {
            geometries[serial] = measured
            return measured
        }
        try await prepare()
        let client = try requireClient()
        let result = try await host.timing.measure(.displayProbe) {
            try await client.shell(AndroidDisplayGeometry.probeScript, on: serial, label: "wm size; wm density; dumpsys input")
        }
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
        statusTasks = [:]
        statusTickets = [:]
        stateReadings = [:]
        cachedDisplayIds = [:]
        avdNames = [:]
        phones = [:]
        listedPhones = [:]
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
