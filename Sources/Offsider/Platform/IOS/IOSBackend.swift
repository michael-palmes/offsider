import Foundation
import FBSimulatorControl
@preconcurrency import FBControlCore
import OffsiderCore

/// Adapter over the existing simulator utilities; each call forwards with the arguments the commands used.
@MainActor
final class IOSBackend: DeviceBackend {
    let logger: OffsiderLogger
    let displayCatalog: IOSDisplayCatalog
    private var simulators: [String: FBSimulator] = [:]
    /// The last whole tree's application frame, which tells a foldable's displays apart when devicectl cannot.
    private(set) var applicationFrames: [String: UIFrame] = [:]
    /// From the last full read, for the hit-tests that follow it; never set on a foldable.
    private var displayZooms: [String: DisplayZoom] = [:]
    private var zoomChecked: Set<String> = []
    private var bootMarkers: [String: String] = [:]
    /// Kept for the command, so a resend or a turn back pays no second activation floor.
    private var vendorLinks: [String: SimulatorDTUHID] = [:]
    private static var isPrepared = false

    init(logger: OffsiderLogger) {
        self.logger = logger
        self.displayCatalog = IOSDisplayCatalog(logger: logger)
    }

    var platform: DevicePlatform { .ios }
    var listingName: String { "iOS Simulators" }

    /// The simulator's vendor-defined service, reconnected when the kept connection stops answering.
    func vendorDefinedLink(for simulator: FBSimulator) async -> Result<SimulatorDTUHID, Error> {
        if let kept = vendorLinks[simulator.udid] {
            if await kept.isAnswering() { return .success(kept) }
            kept.cancel()
            vendorLinks[simulator.udid] = nil
        }
        let connected = await HingeInjector.connect(simulator)
        if case let .success(link) = connected { vendorLinks[simulator.udid] = link }
        return connected
    }

    func close() async {
        let links = vendorLinks.values
        vendorLinks = [:]
        for link in links { await link.close() }
    }

    func prepare() async throws {
        guard !Self.isPrepared else { return }
        try await Timings.measure("prepare") {
            try await setup(logger: logger)
            try await performGlobalSetup(logger: logger)
        }
        Self.isPrepared = true
    }

    func listDevices() async throws -> [DeviceSummary] {
        let simulatorSet = try await getSimulatorSet(logger: logger)
        let iosSimulators = simulatorSet.allSimulators.filter { simulator in
            SimulatorRuntime.isIOS(
                runtimeIdentifier: Self.runtimeIdentifier(of: simulator),
                osVersionName: simulator.osVersion.name.rawValue
            )
        }
        return iosSimulators.map { simulator in
            DeviceSummary(
                id: simulator.udid,
                platform: .ios,
                state: FBiOSTargetStateStringFromState(simulator.state).rawValue,
                name: simulator.name,
                osVersion: simulator.osVersion.name.rawValue,
                deviceType: simulator.deviceType.model.rawValue,
                kind: .simulator
            )
        }
    }

    /// Read through KVC with `responds(to:)` guards because `SimDevice` is a private CoreSimulator class.
    private static func runtimeIdentifier(of simulator: FBSimulator) -> String? {
        guard simulator.responds(to: NSSelectorFromString("device")),
              let device = simulator.value(forKey: "device") as? NSObject,
              device.responds(to: NSSelectorFromString("runtimeIdentifier")) else {
            return nil
        }
        return device.value(forKey: "runtimeIdentifier") as? String
    }

    func requireBootedDevice(_ id: DeviceID) async throws -> BootedDevice {
        let udid = id.rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !udid.isEmpty else {
            throw CLIError(errorDescription: "Device ID cannot be empty. Use --device to choose a device.", reason: .invalidDeviceID, hint: "offsider devices")
        }

        guard let simulator = try await cachedSimulator(udid: udid, logger: logger) else {
            throw CLIError(errorDescription: "Simulator with UDID \(udid) not found.", reason: .deviceNotFound, hint: "offsider devices")
        }

        guard simulator.state == .booted else {
            let stateDescription = FBiOSTargetStateStringFromState(simulator.state).rawValue
            throw CLIError.deviceNotBooted(id: udid, state: stateDescription)
        }

        simulators[udid] = simulator
        return BootedDevice(id: DeviceID(rawValue: udid, platform: .ios), name: simulator.name)
    }

    func accessibilityTree(for id: DeviceID, point: UIPoint?) async throws -> UITree {
        try await accessibilityTree(for: id, point: point, appPIDs: [])
    }

    private func accessibilityTree(for id: DeviceID, point: UIPoint?, appPIDs: Set<Int>) async throws -> UITree {
        let startedAt = Date()
        let tree = try await screenPointTree(for: id, point: point, appPIDs: appPIDs)
        if point == nil {
            if let frame = tree.applicationFrame {
                applicationFrames[id.rawValue] = frame
            }
            DeviceActivityLedger.current.recordTreeRead(tree, on: id, startedAt: startedAt)
        }
        return tree
    }

    /// The tree with its frames in the screen points input and captures use.
    private func screenPointTree(for id: DeviceID, point: UIPoint?, appPIDs: Set<Int>) async throws -> UITree {
        let simulator = try await simulator(for: id)
        let foldable = displayCatalog.isFoldable(simulator)
        // `describe-ui --point` comes with no tree read before it.
        if point != nil, !foldable, !zoomChecked.contains(id.rawValue) {
            _ = try await screenPointTree(for: id, point: nil, appPIDs: [])
        }
        let layoutPoint = point.map { displayZooms[id.rawValue]?.layoutPoint($0) ?? $0 }
        let firstRead: [UINode]
        do {
            firstRead = try await roots(of: simulator, at: layoutPoint, appPIDs: appPIDs)
        } catch {
            guard let point, displayZooms[id.rawValue] == nil,
                  let answer = await springBoardAnswer(at: point, of: simulator, reading: { try await self.roots(of: simulator, at: $0, appPIDs: appPIDs) }) else { throw error }
            return UITree(platform: .ios, device: id.rawValue, roots: answer)
        }
        var tree = UITree(platform: .ios, device: id.rawValue, roots: firstRead)
        if foldable {
            if let active = await displayCatalog.activeDisplay(of: simulator, applicationFrame: tree.applicationFrame),
               let geometry = await panelGeometry(on: active, of: simulator) {
                if Self.isSpringBoard(tree.roots), let turn = geometry.turn {
                    tree.roots = try await springBoardRoots(tree.roots, turn: turn, at: layoutPoint) { try await self.roots(of: simulator, at: $0, appPIDs: appPIDs) }
                }
                tree.roots = UITree.correctingSidewaysApplicationFrame(in: tree.roots, screenWidth: geometry.width, screenHeight: geometry.height)
                tree.roots = UITree.clippingApplicationFrame(in: tree.roots, screenWidth: geometry.width, screenHeight: geometry.height)
            }
            return tree
        }
        if point == nil {
            zoomChecked.insert(id.rawValue)
        }
        if point == nil, tree.roots.contains(where: { $0.role == .application }), let screen = simulator.screenInfo, screen.scale > 0 {
            let scale = Double(screen.scale)
            displayZooms[id.rawValue] = DisplayZoom(in: tree.roots, screenWidth: Double(screen.widthPixels) / scale, screenHeight: Double(screen.heightPixels) / scale)
        }
        if let zoom = displayZooms[id.rawValue] {
            tree.roots = zoom.screenRoots(tree.roots)
        } else if Self.isSpringBoard(tree.roots), let turn = await mainScreenTurn(of: simulator) {
            tree.roots = try await springBoardRoots(tree.roots, turn: turn, at: layoutPoint) { try await self.roots(of: simulator, at: $0, appPIDs: appPIDs) }
        }
        return tree
    }

    private func roots(of simulator: FBSimulator, at point: UIPoint?, appPIDs: Set<Int>) async throws -> [UINode] {
        try IOSAccessibilityMapping.roots(fromJSON: try await AccessibilityFetcher.fetchAccessibilityInfoJSONData(
            from: simulator,
            point: point.map { AccessibilityPoint(x: $0.x, y: $0.y) },
            appPIDs: appPIDs,
            logger: logger
        ))
    }

    /// `read` in screen points; a point read answered by SpringBoard looked in the wrong space, so it is asked again in its own. An app answering there has its own frames, and not the point asked about, so the first answer stands.
    private func springBoardRoots(_ read: [UINode], turn: PanelTurn, at point: UIPoint?, rereading: (UIPoint) async throws -> [UINode]) async throws -> [UINode] {
        guard let point else { return turn.screenRoots(read) }
        guard let again = try? await rereading(turn.panelPoint(point)), Self.isSpringBoard(again) else { return read }
        return turn.screenRoots(again)
    }

    /// A screen point can lie past the panel's edge in SpringBoard's points, so a read that found nothing asks it there before giving up.
    private func springBoardAnswer(at point: UIPoint, of simulator: FBSimulator, reading: (UIPoint) async throws -> [UINode]) async -> [UINode]? {
        guard let turn = await springBoardTurn(of: simulator), let answer = try? await reading(turn.panelPoint(point)), Self.isSpringBoard(answer) else { return nil }
        return turn.screenRoots(answer)
    }

    private func springBoardTurn(of simulator: FBSimulator) async -> PanelTurn? {
        guard displayCatalog.isFoldable(simulator) else { return await mainScreenTurn(of: simulator) }
        guard let active = await displayCatalog.activeDisplay(of: simulator, applicationFrame: nil) else { return nil }
        return await panelGeometry(on: active, of: simulator)?.turn
    }

    private func mainScreenTurn(of simulator: FBSimulator) async -> PanelTurn? {
        guard let screen = simulator.screenInfo, screen.scale > 0,
              let orientation = await SimulatorOrientationReader.currentOrientation(of: simulator, logger: logger) else { return nil }
        return PanelTurn(orientation: orientation.coreOrientation, panelWidth: Double(screen.widthPixels) / Double(screen.scale), panelHeight: Double(screen.heightPixels) / Double(screen.scale))
    }

    private static func isSpringBoard(_ roots: [UINode]) -> Bool {
        roots.first?.iosPID.flatMap { Int32(exactly: $0) }.flatMap(ProcessPath.of(pid:)).map(SimulatorHomePress.isSpringBoard(path:)) == true
    }

    /// Device pixels over scale, swapped when SimulatorKit reports a landscape orientation; on a foldable, the active display's.
    func screenInfo(for id: DeviceID) async throws -> UIScreenInfo? {
        let simulator = try await simulator(for: id)
        if displayCatalog.isFoldable(simulator),
           let active = await displayCatalog.activeDisplay(of: simulator, applicationFrame: applicationFrames[id.rawValue]) {
            return await screenInfo(on: active, of: simulator)
        }
        guard let info = Timings.measure("screen-info", { simulator.screenInfo }), info.scale > 0 else {
            return nil
        }
        let scale = Double(info.scale)
        let orientation = await SimulatorOrientationReader.currentOrientation(of: simulator, logger: logger)
        let portraitWidth = Double(info.widthPixels) / scale
        let portraitHeight = Double(info.heightPixels) / scale
        let isLandscape = orientation?.isLandscape == true
        return UIScreenInfo(
            width: isLandscape ? portraitHeight : portraitWidth,
            height: isLandscape ? portraitWidth : portraitHeight,
            scale: scale,
            rotation: orientation?.coreOrientation
        )
    }

    /// The active display's UI as laid out on its panel, with the device's turn as its rotation; simctl captures it upright.
    func screenInfo(on active: ActiveDisplay, of simulator: FBSimulator) async -> UIScreenInfo {
        let display = active.descriptor
        let geometry = await panelGeometry(on: active, of: simulator)
        return UIScreenInfo(
            width: geometry?.width ?? display.pointWidth,
            height: geometry?.height ?? display.pointHeight,
            scale: display.scale,
            rotation: geometry?.orientation,
            rotationDegrees: geometry?.deviceOrientation?.rotationDegrees,
            display: display.screenDisplay,
            posture: active.posture,
            captureArrivesUpright: true
        )
    }

    /// SimulatorKit's reading for the display's screen, else devicectl's rotation; both are the UI's turn on the panel, not the device's.
    func panelGeometry(on active: ActiveDisplay, of simulator: FBSimulator) async -> PanelGeometry? {
        let display = active.descriptor
        if let read = await SimulatorOrientationReader.currentOrientation(of: simulator, screenID: Int(display.platformId) ?? 1, logger: logger) {
            return PanelGeometry(display: display, orientation: read.coreOrientation)
        }
        guard let degrees = active.rotationDegrees, let orientation = DeviceOrientation(rotationDegrees: degrees) else { return nil }
        return PanelGeometry(display: display, orientation: orientation.coordinateOrientation)
    }

    func deviceCoordinates(
        for points: [(x: Double, y: Double)],
        tree: UITree?,
        on id: DeviceID
    ) async throws -> [(x: Double, y: Double)] {
        if let mapped = try await foldableCoordinates(for: points, tree: tree, on: id) {
            return mapped
        }
        if let tree {
            return try await OrientationAwareCoordinates.translateBatch(
                points: points,
                applicationFrame: tree.applicationFrame,
                for: id.rawValue,
                logger: logger
            )
        }
        let frame = try await screenPointTree(for: id, point: nil, appPIDs: []).applicationFrame
        return try await OrientationAwareCoordinates.translateBatch(points: points, applicationFrame: frame, for: id.rawValue, logger: logger)
    }

    func openInputSession(for id: DeviceID) async throws -> any InputSession {
        if let session = try await displayInputSession(for: id) {
            return session
        }
        var startsBroker = false
        if try Self.keepsInputWarm() {
            switch await Timings.measure("hid-attach", { await HIDBrokerConnection.attach(simulatorUDID: id.rawValue) }) {
            case .ready(let descriptor):
                return SimulatorInputSession(device: id, connection: HIDBrokerConnection(descriptor: descriptor), logger: logger)
            case .absent:
                startsBroker = true
            case .unavailable:
                break
            }
        }
        let hidSession = try await Timings.measure("hid-session") {
            try await HIDInteractor.makeSession(for: id.rawValue, logger: logger)
        }
        simulators[id.rawValue] = hidSession.simulator
        // Started once this command's input is done, so its start does not slow this command.
        return IOSInputSession(hidSession: hidSession, logger: logger, onClose: startsBroker ? { HIDBroker.startInBackground(simulatorUDID: id.rawValue) } : nil)
    }

    /// The broker keeps idb's main-screen digitizer between commands; another display's touches only live as long as this command.
    func sendDetachedTouch(_ steps: [DetachedTouchStep], to id: DeviceID) async throws {
        guard let session = try await displayInputSession(for: id) else {
            try await Self.sendThroughBroker(steps, to: id)
            return
        }
        guard case .down = steps.first, case .up = steps.last else {
            throw CLIError(errorDescription: "touch --down or --up alone is not supported on the iPhone Duo's inner display yet; pass --down and --up together, or fold the simulator to use the cover display.", reason: .notSupported)
        }
        do {
            for step in steps {
                switch step {
                case let .down(x, y): try await session.perform(.touch(direction: .down, x: x, y: y))
                case let .up(x, y): try await session.perform(.touch(direction: .up, x: x, y: y))
                case let .hold(seconds): try await Task.sleep(for: .seconds(seconds))
                }
            }
        } catch {
            await session.close()
            throw error
        }
        await session.close()
    }

    /// Nonisolated so the blocking broker exchange stays off the main actor.
    nonisolated private static func sendThroughBroker(_ steps: [DetachedTouchStep], to id: DeviceID) async throws {
        try HIDBroker.sendDetachedTouch(.composite(steps.map(\.hidEvent)), simulatorUDID: id.rawValue)
    }

    /// `OFFSIDER_SIMULATOR_SESSION`: on unless set to off.
    nonisolated static func keepsInputWarm(_ environment: [String: String] = ProcessInfo.processInfo.environment) throws -> Bool {
        do {
            return try SimulatorSessionSettings.isWarm(environment)
        } catch let invalid as SimulatorSessionSettings.InvalidValue {
            throw CLIError(errorDescription: invalid.description, reason: .usage)
        }
    }

    func screenshotPNG(for id: DeviceID) async throws -> Data {
        try await screenshotPNG(for: id, display: nil)
    }

    /// idb captures the first framebuffer it finds, which on a foldable can be the dark display, so two displays go through simctl.
    func screenshotPNG(for id: DeviceID, display: String?) async throws -> Data {
        let simulator = try await simulator(for: id)
        if displayCatalog.isFoldable(simulator) {
            let screenID: String
            if let display {
                screenID = display
            } else if let active = await displayCatalog.activeDisplay(of: simulator, applicationFrame: applicationFrames[id.rawValue]) {
                screenID = active.descriptor.platformId
            } else {
                screenID = "1"
            }
            return try await Timings.measure("capture") {
                try await SimctlScreenshot.capturePNG(udid: id.rawValue, display: screenID, logger: logger)
            }
        }
        if let display, display != "1" {
            throw CLIError(errorDescription: "Simulator \(id.rawValue) has one display, 1 (main); got \(display). Run `offsider displays --device \(id.rawValue)`.", reason: .unknownDisplay, hint: "offsider displays --device \(id.rawValue)")
        }
        return try await Timings.measure("capture") {
            try await VideoFrameUtilities.captureScreenshotData(from: simulator)
        }
    }

    /// The status bar; the home indicator does not change on its own.
    func volatileScreenBands(for id: DeviceID) async -> ScreenBands {
        ScreenBands(top: Self.statusBarHeight, bottom: 0)
    }

    static let statusBarHeight = 60.0

    func simulator(for id: DeviceID) async throws -> FBSimulator {
        if let simulator = simulators[id.rawValue] {
            return simulator
        }
        guard let simulator = try await cachedSimulator(udid: id.rawValue, logger: logger) else {
            throw CLIError.deviceNotFound(id: id.rawValue)
        }
        guard simulator.state == .booted else {
            throw CLIError.deviceNotBooted(id: id.rawValue, state: FBiOSTargetStateStringFromState(simulator.state).rawValue)
        }
        simulators[id.rawValue] = simulator
        return simulator
    }
}

extension IOSBackend: PointHitTesting {
    func hitTest(at point: UIPoint, on id: DeviceID, appPIDs: Set<Int>) async throws -> UINode? {
        try await accessibilityTree(for: id, point: point, appPIDs: appPIDs).roots.first
    }

    func quickHitTest(at point: UIPoint, on id: DeviceID) async throws -> UINode? {
        try await probe(at: point, on: id)
    }

    /// A simulator's processes run on the Mac, so the pid the tree gives is a Mac pid.
    func processName(of pid: Int, on id: DeviceID) async -> String? {
        var path = [CChar](repeating: 0, count: Int(4 * MAXPATHLEN))
        guard pid > 0, proc_pidpath(Int32(pid), &path, UInt32(path.count)) > 0 else { return nil }
        let name = URL(fileURLWithPath: String(cString: path)).lastPathComponent
        return name.isEmpty ? nil : name
    }
}

extension IOSBackend: PresentationProbing {
    func probe(at point: UIPoint, on id: DeviceID) async throws -> UINode? {
        let zoom = displayZooms[id.rawValue]
        let layoutPoint = zoom?.layoutPoint(point) ?? point
        let simulator = try await simulator(for: id)
        let read = { (point: UIPoint) in
            try IOSAccessibilityMapping.roots(fromJSON: try await AccessibilityFetcher.probeAccessibilityJSONData(from: simulator, at: AccessibilityPoint(x: point.x, y: point.y)))
        }
        var roots: [UINode]
        do {
            roots = try await read(layoutPoint)
        } catch {
            guard zoom == nil, let answer = await springBoardAnswer(at: point, of: simulator, reading: read) else { throw error }
            return answer.first
        }
        if zoom == nil, Self.isSpringBoard(roots), let turn = await springBoardTurn(of: simulator) {
            roots = try await springBoardRoots(roots, turn: turn, at: point, rereading: read)
        }
        return (zoom?.screenRoots(roots) ?? roots).first
    }

    func knowsDisplayZoom(on id: DeviceID) -> Bool {
        displayZooms[id.rawValue] != nil
    }
}

extension IOSBackend: TreeGapFilling {
    func startGapSamples(on id: DeviceID) async -> GapSamples? {
        guard let size = try? await screenSize(for: id), size.width > 0, size.height > 0,
              let simulator = try? await simulator(for: id) else { return nil }
        let points = TreeGapFill.samplePoints(in: UIFrame(x: 0, y: 0, width: size.width, height: size.height), rows: TreeGapFill.earlySampleRows, belowStatusBar: Self.statusBarHeight)
        let hits = Task { await Self.pointElements(at: points, from: simulator, zoom: self.displayZooms[id.rawValue]) }
        // Lets the hit-tests send their requests before the tree read takes the main actor.
        await Task.yield()
        return GapSamples(points: points, answers: { wanted, isNew in
            await self.nodes(from: await hits.value, wanted: wanted, isNew: isNew, on: id)
        }, zoomKnown: knowsDisplayZoom(on: id))
    }

    func fillingGaps(in tree: UITree, on id: DeviceID, samples: GapSamples?) async -> UITree {
        let filled = try? await DoctorProbes.withTimeout(TreeGapFill.overallLimit, operation: "Reading what the app hides") {
            await self.filling(tree, on: id, samples: samples)
        }
        return filled ?? tree
    }

    private func filling(_ tree: UITree, on id: DeviceID, samples: GapSamples?) async -> UITree {
        await Timings.measure("gap-fill") {
            guard let simulator = try? await simulator(for: id) else { return tree }
            // SpringBoard hides nothing, and on a turned screen its point reads would not line up with the tree, so each would look like a hidden element.
            if Self.isSpringBoard(tree.roots), await springBoardTurn(of: simulator) != nil {
                _ = await samples?.answers(samples?.points.map { _ in false } ?? []) { _ in false }
                return tree
            }
            let read = { (points: [UIPoint], wanted: [Bool], isNew: (UINode) -> Bool) async -> [UINode?] in
                let elements = await Self.pointElements(at: points, from: simulator, zoom: self.displayZooms[id.rawValue])
                return self.nodes(from: elements, wanted: wanted, isNew: isNew, on: id)
            }
            // Started with no zoom known on a device that has one, the sample hit-tests looked in the wrong place.
            if let samples, samples.zoomKnown || !knowsDisplayZoom(on: id) {
                return await TreeGapFill.filling(tree, points: samples.points, samples: samples.answers) { points, isNew in
                    await read(points, points.map { _ in true }, isNew)
                }
            }
            guard let viewport = tree.visibleRect else { return tree }
            let points = TreeGapFill.samplePoints(in: viewport, belowStatusBar: Self.statusBarHeight)
            return await TreeGapFill.filling(tree, points: points, samples: { wanted, isNew in
                await read(points, wanted, isNew)
            }, read: { points, isNew in
                await read(points, points.map { _ in true }, isNew)
            })
        }
    }

    /// All the hit-tests at once, in layout points on a zoomed device; a failed one leaves nil.
    nonisolated private static func pointElements(at points: [UIPoint], from simulator: FBSimulator, zoom: DisplayZoom?) async -> [FBAccessibilityElement?] {
        await withTaskGroup(of: (Int, FBAccessibilityElement?).self) { group in
            for (index, point) in points.enumerated() {
                group.addTask {
                    let layout = zoom?.layoutPoint(point) ?? point
                    return (index, try? await AccessibilityFetcher.pointElement(from: simulator, at: AccessibilityPoint(x: layout.x, y: layout.y)))
                }
            }
            var elements = [FBAccessibilityElement?](repeating: nil, count: points.count)
            for await (index, element) in group { elements[index] = element }
            return elements
        }
    }

    /// Serialises one at a time what `wanted` marks: identity first, everything only for what `isNew` picks. Closes every element.
    private func nodes(from elements: [FBAccessibilityElement?], wanted: [Bool], isNew: (UINode) -> Bool, on id: DeviceID) -> [UINode?] {
        let zoom = displayZooms[id.rawValue]
        func node(_ element: FBAccessibilityElement, keys: Set<FBAXKeys>) -> UINode? {
            guard let data = try? AccessibilityFetcher.serialized(element, keys: keys), let roots = try? IOSAccessibilityMapping.roots(fromJSON: data) else { return nil }
            return (zoom?.screenRoots(roots) ?? roots).first
        }
        defer { elements.forEach { $0?.close() } }
        return zip(elements, wanted).map { element, wanted in
            guard wanted, let element, let identity = node(element, keys: AccessibilityFetcher.identityKeys) else { return nil }
            return isNew(identity) ? node(element, keys: TraitsRequest.process.keys) ?? identity : identity
        }
    }
}

extension IOSBackend: RawAccessibilitySource {
    func rawAccessibilitySource(for id: DeviceID) async throws -> Data {
        try await AccessibilityFetcher.fetchAccessibilityInfoJSONData(from: try await simulator(for: id), logger: logger)
    }
}

extension IOSBackend: RawVideoStreaming {
    func streamBGRA(
        from id: DeviceID,
        fps: Int,
        quality: Int,
        scale: Double,
        to fileDescriptor: Int32,
        isCancelled: @escaping @Sendable () async -> Bool
    ) async throws {
        let simulator = try await self.simulator(for: id)

        let config = FBVideoStreamConfiguration(
            format: .bgra(),
            framesPerSecond: NSNumber(value: fps),
            rateControl: .quality(NSNumber(value: Double(quality) / 100.0)),
            scaleFactor: NSNumber(value: scale),
            keyFrameRate: nil
        )

        let stdoutConsumer = FBFileWriter.syncWriter(withFileDescriptor: fileDescriptor, closeOnEndOfFile: false)
        var videoStream: (any FBVideoStream)?
        var isStreaming = false

        do {
            let stream = try await simulator.createStream(configuration: config)
            videoStream = stream
            try await stream.startStreamingAsync(stdoutConsumer)
            isStreaming = true
            try await Task.sleep(nanoseconds: 1_000_000_000)
            Console.current.aside("BGRA stream is now running...", person: nil)

            while true {
                if Task.isCancelled {
                    break
                }
                if await isCancelled() {
                    break
                }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }

            Console.current.aside("\nStopping BGRA stream...", person: nil)
            isStreaming = false
            try await stream.stopStreamingAsync()
            Console.current.clearLine()
            Console.current.aside("BGRA stream stopped", person: "Stream stopped")
        } catch {
            if isStreaming, let videoStream {
                isStreaming = false
                try? await videoStream.stopStreamingAsync()
            }
            throw CLIError(errorDescription: "Failed to stream BGRA video: \(error.localizedDescription)", reason: .videoFailed)
        }
    }
}

extension DetachedTouchStep {
    var hidEvent: FBSimulatorHIDEvent {
        switch self {
        case let .down(x, y):
            return .touch(direction: .down, x: x, y: y)
        case let .up(x, y):
            return .touch(direction: .up, x: x, y: y)
        case let .hold(duration):
            return .delay(duration)
        }
    }
}

extension IOSBackend: BootMarking {
    /// The device's `launchd_sim` start time, read once per command.
    func bootMarker(for id: DeviceID) async -> String? {
        if let marker = bootMarkers[id.rawValue] { return marker }
        guard let marker = Self.bootMarker(simulatorUDID: id.rawValue) else { return nil }
        bootMarkers[id.rawValue] = marker
        return marker
    }

    /// `launchd_sim <seconds>.<microseconds>` from the local process table; nil when the simulator is not booted.
    nonisolated static func bootMarker(simulatorUDID: String) -> String? {
        guard let identity = try? HIDBroker.currentBootIdentity(simulatorUDID: simulatorUDID) else { return nil }
        return "launchd_sim \(identity.startSeconds).\(String(format: "%06d", identity.startMicroseconds))"
    }
}
