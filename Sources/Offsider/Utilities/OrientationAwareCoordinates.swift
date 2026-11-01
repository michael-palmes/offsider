import Foundation
import OffsiderCore
import FBControlCore
import FBSimulatorControl

// MARK: - Simulator Orientation

/// SimulatorKit's `uiOrientation` 1 to 4 in case order; `landscape` is the device turned clockwise (landscape-right).
enum SimulatorOrientation: String, CaseIterable {
    case portrait
    case portraitUpsideDown
    case landscape
    case landscapeFlipped

    /// True when the logical screen width is wider than tall.
    var isLandscape: Bool {
        coreOrientation.isLandscape
    }

    var coreOrientation: OrientationCoordinateMath.Orientation {
        switch self {
        case .portrait:
            return .portrait
        case .portraitUpsideDown:
            return .portraitUpsideDown
        case .landscape:
            return .landscape
        case .landscapeFlipped:
            return .landscapeFlipped
        }
    }
}

// MARK: - Coordinate Mapping

/// Describes how logical coordinates from the accessibility tree map to the physical
/// portrait coordinate space that FBSimulatorHIDEvent expects.
///
/// The AX application frame alone cannot distinguish two landscape cases:
///   - **Rotation:**  hardware is in landscape (device rotated). Rotation math applies.
///   - **Letterbox:** hardware is portrait, but the app declares landscape-only
///     orientations. iOS scales + centers the landscape UI inside the portrait
///     viewport. Scale + offset math applies.
///
/// Detection: read SimulatorKit's private screen `uiOrientation` when available,
/// then fall back to screenshot pixel aspect ratio to distinguish portrait-hardware
/// letterboxing from a rotated simulator.
enum CoordinateMapping {
    /// Portrait device, portrait app: pass coordinates through unchanged.
    case passthrough

    /// Hardware is rotated. Apply rotation math.
    ///
    /// `portraitSize` = `(width: shortSide, height: longSide)` in logical points.
    case rotation(SimulatorOrientation, portraitSize: (width: Double, height: Double))

    /// Hardware is portrait, app is landscape-only. Apply letterbox scale + offset.
    ///
    /// Physical point = `(offsetX + lx * scale, offsetY + ly * scale)`.
    case letterbox(scale: Double, offsetX: Double, offsetY: Double)
}

// MARK: - Orientation-Aware Coordinate Translation

/// Translates logical UI coordinates (as reported by the accessibility tree and
/// consumed by `offsider tap`, `offsider touch`, and `offsider swipe`) into the physical portrait
/// coordinate space that FBSimulatorHIDEvent expects.
///
/// ## Root cause
/// The iOS Simulator's HID layer always operates in physical portrait space.
/// The accessibility tree, however, reports element positions in the *logical*
/// orientation the app currently presents.  When the device is rotated, logical
/// coordinates must be mapped back to physical portrait before dispatching HID
/// events, otherwise taps land in the wrong location.
///
/// ## Two landscape cases
/// Both a rotated device and a portrait device running a landscape-only app produce
/// a landscape-shaped AX application frame. Offsider first asks the simulator's private
/// screen properties for the current UI orientation so it can distinguish landscape
/// left from landscape right automatically. If that private probe is unavailable,
/// screenshot dimensions are used only to distinguish rotated hardware from a
/// portrait device running a letterboxed landscape-only app. If the screenshot
/// confirms rotated hardware but private orientation is unavailable, Offsider fails
/// clearly instead of guessing landscape direction.
///
/// ## Portrait dimensions
/// The short side of the device in points is the portrait width; the long side
/// is the portrait height.  These are derived from the application frame: in
/// portrait they are `frame.width` and `frame.height`; in landscape they are
/// swapped.
@MainActor
struct OrientationAwareCoordinates {

    // MARK: - Coordinate Mapping Detection

    /// Determines which coordinate mapping to apply for the given simulator.
    ///
    /// Detection flow:
    /// 1. If an explicit override was supplied → rotation case.
    /// 2. Otherwise read SimulatorKit private UI orientation.
    /// 3. If private orientation is unavailable and the AX frame is portrait-shaped → passthrough.
    /// 4. If unavailable and landscape-shaped, probe screenshot dimensions.
    ///    - Screenshot portrait-shaped (taller than wide) → letterbox case.
    ///    - Screenshot landscape-shaped (wider than tall) → rotated device case.
    ///
    /// - Parameters:
    ///   - applicationFrame: The AX application frame, converted for Display Zoom by the caller.
    ///   - simulatorUDID: Target simulator UDID.
    ///   - screenID: The screen whose orientation to read.
    ///   - orientationOverride: Forces a specific rotated-device `SimulatorOrientation`.
    ///     Intended for internal tests or future explicit callers; normal CLI commands
    ///     rely on automatic private orientation detection.
    ///   - logger: Offsider logger instance.
    /// - Returns: The `CoordinateMapping` that applies to the current simulator state.
    static func detectMapping(
        applicationFrame: UIFrame?,
        simulatorUDID: String,
        screenID: Int = 1,
        orientationOverride: SimulatorOrientation? = nil,
        logger: OffsiderLogger
    ) async throws -> CoordinateMapping {
        guard let appFrame = applicationFrame else {
            throw CLIError(errorDescription: "Unable to determine coordinate mapping because the accessibility application frame is unavailable.", reason: .orientationUnknown)
        }

        if let orientationOverride {
            logger.info().log("Using explicit orientation override: \(orientationOverride.rawValue)")
            return .rotation(orientationOverride, portraitSize: portraitDimensions(applicationFrame: appFrame, orientation: orientationOverride))
        }

        // Prefer the simulator's private UI orientation state when available; this
        // distinguishes landscape-left from landscape-right and catches upside-down portrait.
        let simulatorOrientation = await SimulatorOrientationReader.currentOrientation(
            simulatorUDID: simulatorUDID,
            screenID: screenID,
            logger: logger
        )

        if let simulatorOrientation {
            logger.info().log("Detected simulator UI orientation: \(simulatorOrientation.rawValue)")
            let portraitSize = portraitDimensions(applicationFrame: appFrame, orientation: simulatorOrientation)

            switch simulatorOrientation {
            case .portrait:
                guard appFrame.width > appFrame.height else {
                    return .passthrough
                }
                logger.info().log(
                    "Simulator reports portrait but AX frame \(Int(appFrame.width))×\(Int(appFrame.height)) is landscape; probing for letterbox mapping"
                )
            case .portraitUpsideDown, .landscape, .landscapeFlipped:
                return .rotation(simulatorOrientation, portraitSize: portraitSize)
            }
        }

        guard appFrame.width > appFrame.height else {
            logger.info().log(
                "AX frame \(Int(appFrame.width))×\(Int(appFrame.height)) is portrait; passthrough"
            )
            return .passthrough
        }

        // Fall back to screenshot aspect ratio to distinguish rotated hardware from a
        // portrait device running a landscape-only app.
        logger.info().log(
            "AX frame \(Int(appFrame.width))×\(Int(appFrame.height)) is landscape; probing screenshot dimensions"
        )

        let screenshotDims = await screenshotPixelDimensions(for: simulatorUDID, logger: logger)

        if let dims = screenshotDims, dims.height > dims.width {
            // Screenshot is portrait-shaped despite a landscape AX frame →
            // hardware is portrait, app is landscape-only: letterbox case.
            logger.info().log(
                "Screenshot \(dims.width)×\(dims.height)px is portrait-shaped; using letterbox mapping"
            )

            // Physical viewport in points: short side = portrait width, long side = portrait height.
            // Derived from the landscape AX frame by swapping axes (same as portraitDimensions).
            let physW = appFrame.height  // portrait width  = landscape logical height
            let physH = appFrame.width   // portrait height = landscape logical width
            let logW  = appFrame.width   // logical landscape width
            let logH  = appFrame.height  // logical landscape height

            // Uniform scale to fit logical content into physical viewport.
            let scale = min(physW / logW, physH / logH)
            let offsetX = (physW - logW * scale) / 2
            let offsetY = (physH - logH * scale) / 2

            logger.info().log(
                String(format: "Letterbox: scale=%.4f offsetX=%.1f offsetY=%.1f", scale, offsetX, offsetY)
            )
            return .letterbox(scale: scale, offsetX: offsetX, offsetY: offsetY)
        }

        guard let screenshotDims else {
            throw CLIError(errorDescription: "Unable to determine coordinate mapping because screenshot probing failed for a landscape accessibility frame.", reason: .orientationUnknown)
        }

        // Screenshot is landscape-shaped: hardware is rotated.
        logger.info().log(
            "Screenshot \(screenshotDims.width)×\(screenshotDims.height)px is landscape-shaped; using rotation mapping"
        )

        throw CLIError(errorDescription: "Unable to determine rotated simulator orientation. Offsider can read landscape coordinates only when SimulatorKit reports the current UI orientation; the screenshot confirms the simulator is rotated, but the private orientation probe was unavailable.", reason: .orientationUnknown)
    }

    // MARK: - Screenshot Dimension Probe

    static func screenshotPixelDimensions(
        for simulatorUDID: String,
        logger: OffsiderLogger
    ) async -> (width: Int, height: Int)? {
        await SimctlScreenshot.pixelDimensions(udid: simulatorUDID, logger: logger)
    }

    // MARK: - Coordinate Translation

    /// Translates a logical point (as reported by the accessibility tree) to the
    /// physical portrait point expected by FBSimulatorHIDEvent using rotation math.
    ///
    /// - Parameters:
    ///   - point: Logical (x, y) in the current UI orientation.
    ///   - orientation: The current logical orientation of the simulator.
    ///   - portraitSize: The device's portrait dimensions `(width: shortSide, height: longSide)`.
    /// - Returns: Physical (x, y) in portrait space.
    static func translateToPhysical(
        point: (x: Double, y: Double),
        orientation: SimulatorOrientation,
        portraitSize: (width: Double, height: Double)
    ) -> (x: Double, y: Double) {
        OrientationCoordinateMath.translateToPhysical(
            x: point.x,
            y: point.y,
            orientation: orientation.coreOrientation,
            portraitWidth: portraitSize.width,
            portraitHeight: portraitSize.height
        )
    }

    /// Translates a logical point to a physical point using letterbox scale + offset math.
    ///
    /// iOS places a landscape-only app inside the portrait viewport by scaling it
    /// uniformly and centering it. The physical point is:
    ///
    ///   `px = offsetX + lx * scale`
    ///   `py = offsetY + ly * scale`
    ///
    /// - Parameters:
    ///   - point:   Logical (x, y) as reported by the AX tree.
    ///   - scale:   Uniform scale factor (`min(physW / logW, physH / logH)`).
    ///   - offsetX: Horizontal letterbox offset in points (`(physW - logW * scale) / 2`).
    ///   - offsetY: Vertical letterbox offset in points (`(physH - logH * scale) / 2`).
    /// - Returns: Physical (x, y) in the portrait hardware viewport.
    static func letterboxToPhysical(
        point: (x: Double, y: Double),
        scale: Double,
        offsetX: Double,
        offsetY: Double
    ) -> (x: Double, y: Double) {
        OrientationCoordinateMath.letterboxToPhysical(
            x: point.x,
            y: point.y,
            scale: scale,
            offsetX: offsetX,
            offsetY: offsetY
        )
    }

    /// Derives the device's portrait dimensions from the accessibility tree.
    ///
    /// In portrait, the application frame is already in portrait coordinates.
    /// In landscape, the width and height are swapped compared to portrait.
    ///
    /// - Parameters:
    ///   - applicationFrame: The accessibility application frame.
    ///   - orientation: The current logical orientation.
    /// - Returns: Portrait `(width, height)`.
    static func portraitDimensions(
        applicationFrame frame: UIFrame,
        orientation: SimulatorOrientation
    ) -> (width: Double, height: Double) {
        if orientation.isLandscape {
            // In landscape: logical width = portrait height, logical height = portrait width
            return (width: frame.height, height: frame.width)
        }
        return (width: frame.width, height: frame.height)
    }

    // MARK: - Full Pipeline

    /// Translates several logical points using a single detection round-trip.
    static func translateBatch(
        points: [(x: Double, y: Double)],
        applicationFrame: UIFrame?,
        for simulatorUDID: String,
        screenID: Int = 1,
        orientationOverride: SimulatorOrientation? = nil,
        logger: OffsiderLogger
    ) async throws -> [(x: Double, y: Double)] {
        let mapping = try await detectMapping(
            applicationFrame: applicationFrame,
            simulatorUDID: simulatorUDID,
            screenID: screenID,
            orientationOverride: orientationOverride,
            logger: logger
        )

        return points.map { applyMapping(mapping, to: $0, logger: logger) }
    }

    // MARK: - Private Helpers

    /// Applies a `CoordinateMapping` to a single logical point, logging the translation.
    private static func applyMapping(
        _ mapping: CoordinateMapping,
        to point: (x: Double, y: Double),
        logger: OffsiderLogger
    ) -> (x: Double, y: Double) {
        let physical: (x: Double, y: Double)

        switch mapping {
        case .passthrough:
            return point

        case .rotation(let orientation, let portraitSize):
            physical = translateToPhysical(point: point, orientation: orientation, portraitSize: portraitSize)
            logger.info().log(
                "Translated logical (\(Int(point.x)), \(Int(point.y))) → physical (\(Int(physical.x)), \(Int(physical.y))) [rotation: \(orientation.rawValue)]"
            )

        case .letterbox(let scale, let offsetX, let offsetY):
            physical = letterboxToPhysical(point: point, scale: scale, offsetX: offsetX, offsetY: offsetY)
            logger.info().log(
                String(format: "Translated logical (%d, %d) → physical (%.1f, %.1f) [letterbox: scale=%.4f offsetX=%.1f offsetY=%.1f]",
                       Int(point.x), Int(point.y), physical.x, physical.y, scale, offsetX, offsetY)
            )
        }

        return physical
    }
}
