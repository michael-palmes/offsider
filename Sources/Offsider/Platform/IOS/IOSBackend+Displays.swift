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
        let screen = screenInfo(on: active, of: simulator)
        let posture = await displayCatalog.posture(of: simulator, applicationFrame: frame)
        let displays = (displayCatalog.profile(of: simulator) ?? []).map { descriptor in
            guard descriptor.platformId == active.descriptor.platformId else {
                return DisplayInfo(
                    descriptor: descriptor, pointWidth: descriptor.pointWidth, pointHeight: descriptor.pointHeight,
                    rotationDegrees: active.rotations[descriptor.platformId], active: false
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

    /// On a foldable, the active display's coordinates; nil leaves a one-display simulator to the usual mapping.
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
              let main = simulator.screenInfo, main.scale > 0 else {
            return nil
        }
        let display = active.descriptor
        let screenID = Int(display.platformId) ?? 1
        if display.pixelWidth == Int(main.widthPixels), display.pixelHeight == Int(main.heightPixels) {
            return try await OrientationAwareCoordinates.translateBatch(
                points: points, applicationFrame: frame, for: id.rawValue, screenID: screenID, logger: logger
            )
        }
        let orientation = interfaceOrientation(on: active, of: simulator) ?? .portrait
        let turned = OrientationCoordinateMath.Orientation(
            uprightQuarterTurnsCounterclockwise: orientation.uprightQuarterTurnsCounterclockwise(nativeDegrees: display.nativeOrientation)
        )
        let mainScale = Double(main.scale)
        return points.map { point in
            let physical = OrientationCoordinateMath.translateToPhysical(
                x: point.x, y: point.y, orientation: turned, portraitWidth: display.pointWidth, portraitHeight: display.pointHeight
            )
            return OrientationCoordinateMath.scaleToMainScreen(
                x: physical.x, y: physical.y,
                displayWidth: display.pointWidth, displayHeight: display.pointHeight,
                mainWidth: Double(main.widthPixels) / mainScale, mainHeight: Double(main.heightPixels) / mainScale
            )
        }
    }
}

extension IOSBackend: PostureControlling {
    func posture(of id: DeviceID) async throws -> Posture? {
        let simulator = try await simulator(for: id)
        guard displayCatalog.isFoldable(simulator) else { return nil }
        return await displayCatalog.posture(of: simulator, applicationFrame: applicationFrames[id.rawValue], refresh: true)
    }

    func requestPosture(_ posture: Posture, on id: DeviceID) async throws {
        throw CLIError(errorDescription: Self.postureUnavailable(device: id.rawValue))
    }

    static func postureUnavailable(device: String) -> String {
        "Setting the posture is not available on iOS simulators: no simulator tool folds the device. Fold or unfold it in Device Hub, then check with `offsider posture --device \(device)`."
    }
}
