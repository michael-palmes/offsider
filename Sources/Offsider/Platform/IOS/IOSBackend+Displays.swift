import FBSimulatorControl
import Foundation
import OffsiderCore

extension IOSBackend: DisplayCapturing {}

extension IOSBackend: DisplayControlling {
    func displays(of id: DeviceID) async throws -> DisplayList {
        let simulator = try await simulator(for: id)
        let frame = applicationFrames[id.rawValue]
        guard displayCatalog.isFoldable(simulator),
              let active = await displayCatalog.activeDisplay(of: simulator, applicationFrame: frame, refresh: true) else {
            return try await singleDisplay(of: simulator, id: id)
        }
        let screen = await screenInfo(on: active, of: simulator)
        let posture = await displayCatalog.posture(of: simulator, applicationFrame: frame)
        // An inactive display shows no UI, so it has no rotation to report.
        let displays = (displayCatalog.profile(of: simulator) ?? []).map { descriptor in
            guard descriptor.platformId == active.descriptor.platformId else {
                return DisplayInfo(
                    descriptor: descriptor, pointWidth: descriptor.pointWidth, pointHeight: descriptor.pointHeight,
                    rotationDegrees: nil, active: false
                )
            }
            return DisplayInfo(
                descriptor: descriptor, pointWidth: screen.width, pointHeight: screen.height,
                rotationDegrees: screen.resolvedRotationDegrees, active: true
            )
        }
        return DisplayList(displays: displays, posture: posture ?? active.posture)
    }

    private func singleDisplay(of simulator: FBSimulator, id: DeviceID) async throws -> DisplayList {
        guard let screen = try await screenInfo(for: id), let scale = screen.scale else {
            throw CLIError(errorDescription: "Offsider could not read the screen of simulator \(id.rawValue). Check it is booted with `offsider list-devices`.")
        }
        let profiled = displayCatalog.profile(of: simulator)?.first
        let portrait = screen.rotation?.isLandscape == true ? (screen.height, screen.width) : (screen.width, screen.height)
        let descriptor = profiled ?? DisplayDescriptor(
            role: .main, platformId: "1", name: "LCD",
            pixelWidth: Int((portrait.0 * scale).rounded()), pixelHeight: Int((portrait.1 * scale).rounded()),
            scale: scale, nativeOrientation: 0
        )
        let display = DisplayInfo(
            descriptor: descriptor, pointWidth: screen.width, pointHeight: screen.height,
            rotationDegrees: screen.resolvedRotationDegrees, active: true
        )
        return DisplayList(displays: [display], posture: nil)
    }

    /// On a foldable, the active display's coordinates in idb's main-screen points; nil leaves a one-display simulator to the usual mapping.
    func foldableCoordinates(
        for points: [(x: Double, y: Double)],
        tree: UITree?,
        on id: DeviceID
    ) async throws -> [(x: Double, y: Double)]? {
        let simulator = try await simulator(for: id)
        guard displayCatalog.isFoldable(simulator) else { return nil }
        let resolvedTree: UITree
        if let tree {
            resolvedTree = tree
        } else {
            resolvedTree = try await accessibilityTree(for: id)
        }
        let frame = resolvedTree.applicationFrame
        guard let active = await displayCatalog.activeDisplay(of: simulator, applicationFrame: frame, preferFrame: true),
              let main = mainScreenPoints(of: simulator) else {
            return nil
        }
        let display = active.descriptor
        if Self.isMainScreen(display, main: main) {
            return try await OrientationAwareCoordinates.translateBatch(
                points: points, applicationFrame: frame, for: id.rawValue, screenID: Int(display.platformId) ?? 1, logger: logger
            )
        }
        guard let geometry = await panelGeometry(on: active, of: simulator) else {
            throw CLIError(errorDescription: "Offsider could not read how the UI is turned on the \(display.role.rawValue) display of \(id.rawValue), so it cannot place input there. Check with `offsider displays --device \(id.rawValue)`, then retry.")
        }
        return points.map { geometry.mainScreenPoint(x: $0.x, y: $0.y, mainWidth: main.width, mainHeight: main.height) }
    }

    /// A session for a foldable's display that is not the main screen, whose touchscreen idb cannot reach; nil otherwise.
    func displayInputSession(for id: DeviceID) async throws -> IOSDisplayInputSession? {
        let simulator = try await simulator(for: id)
        guard displayCatalog.isFoldable(simulator),
              let active = await displayCatalog.activeDisplay(of: simulator, applicationFrame: applicationFrames[id.rawValue]),
              let main = mainScreenPoints(of: simulator),
              !Self.isMainScreen(active.descriptor, main: main),
              let screenID = UInt64(active.descriptor.platformId) else {
            return nil
        }
        return IOSDisplayInputSession(device: id, simulator: simulator, screenID: screenID, mainSize: main, logger: logger)
    }

    /// The device type's main screen, whose points idb turns into touch fractions.
    private func mainScreenPoints(of simulator: FBSimulator) -> (width: Double, height: Double)? {
        guard let main = simulator.screenInfo, main.scale > 0 else { return nil }
        return (Double(main.widthPixels) / Double(main.scale), Double(main.heightPixels) / Double(main.scale))
    }

    static func isMainScreen(_ display: DisplayDescriptor, main: (width: Double, height: Double)) -> Bool {
        abs(display.pointWidth - main.width) < 0.5 && abs(display.pointHeight - main.height) < 0.5
    }
}

extension IOSBackend: PostureControlling, HingeControlling {
    func posture(of id: DeviceID) async throws -> Posture? {
        let simulator = try await simulator(for: id)
        guard displayCatalog.isFoldable(simulator) else { return nil }
        return await displayCatalog.posture(of: simulator, applicationFrame: applicationFrames[id.rawValue], refresh: true)
    }

    func requestPosture(_ posture: Posture, on id: DeviceID) async throws {
        guard let angle = HingeControl.angle(for: posture) else {
            throw CLIError(errorDescription: "Posture \(posture.rawValue) cannot be set. Use closed, half-opened or open.")
        }
        try await requestHingeAngle(angle, on: id)
    }

    func hingeAngle(of id: DeviceID) async throws -> Double? {
        let simulator = try await simulator(for: id)
        guard displayCatalog.isFoldable(simulator) else { return nil }
        return await displayCatalog.hingeAngle(of: simulator)
    }

    /// Sweeps from the hinge's reading, else the last posture's angle: the panels only swap when the hinge moves smoothly. Dispatch only; a hinge already at `degrees` with its panel showing is left alone.
    func requestHingeAngle(_ degrees: Int, on id: DeviceID) async throws {
        let simulator = try await simulator(for: id)
        guard displayCatalog.isFoldable(simulator) else {
            throw CLIError(errorDescription: DisplayReport.notFoldable(device: id.rawValue))
        }
        var reading = await displayCatalog.hingeAngle(of: simulator).map { Int($0.rounded()) }
        if reading == degrees {
            let active = await displayCatalog.activeDisplay(of: simulator, applicationFrame: applicationFrames[id.rawValue], refresh: true)
            guard let active, !HingeControl.panelMatches(active.posture ?? .unknown, angle: degrees) else {
                logger.info().log("Hinge: already at \(degrees) degrees, not sweeping")
                return
            }
            logger.info().log("Hinge: at \(degrees) degrees but the \(active.descriptor.role.rawValue) display is active, so sweeping from the far end")
            reading = HingeControl.start(from: nil, to: degrees)
        }
        let start = reading ?? HingeControl.start(from: displayCatalog.lastPosture(of: simulator), to: degrees)
        defer { displayCatalog.forgetReadings(of: simulator.udid) }
        do {
            try await HingeInjector.sweep(simulator, from: start, to: degrees, logger: logger)
        } catch let failure as SimulatorDTUHID.Failure {
            logger.info().log("Hinge: \(failure)")
            throw CLIError(errorDescription: Self.postureUnavailable(device: id.rawValue))
        }
    }

    static func postureUnavailable(device: String) -> String {
        "Setting the posture is not available on this iOS simulator: its runtime has no hinge service Offsider can reach. Fold or unfold it in Device Hub, then check with `offsider posture --device \(device)`."
    }
}
