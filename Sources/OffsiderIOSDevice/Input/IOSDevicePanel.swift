import Foundation
import OffsiderCore

/// A device's touch panel in points, on its native axes, and how the UI currently sits on it.
/// The digitizer takes fractions of this panel, as a simulator's does of its framebuffer.
public struct IOSDevicePanel: Equatable, Sendable {
    /// Points along the panel's native axes: a phone is taller than wide, an iPad Pro is wider than tall.
    public var width: Double
    public var height: Double
    public var scale: Double
    /// The UI's turn on the panel; `.portrait` when the UI follows the native axes.
    public var orientation: OrientationCoordinateMath.Orientation

    public init(width: Double, height: Double, scale: Double, orientation: OrientationCoordinateMath.Orientation) {
        self.width = width
        self.height = height
        self.scale = scale
        self.orientation = orientation
    }

    /// The primary integrated display from `devicectl device info displays`: `nativeSize` pixels over `pointScale`, measured in
    /// the UI's points from `bounds` when it reports them, and turned by `currentOrientation`, which devicectl reports clockwise.
    public static func parse(displaysJSON data: Data) -> IOSDevicePanel? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = root["result"] as? [String: Any],
              let displays = result["displays"] as? [[String: Any]] else { return nil }
        let display = displays.first { ($0["primary"] as? Bool) == true } ?? displays.first
        guard let display,
              let size = display["nativeSize"] as? [NSNumber], size.count == 2,
              let scale = (display["pointScale"] as? NSNumber)?.doubleValue, scale > 0 else { return nil }
        let clockwise = DevicectlDisplays.degrees(display["currentOrientation"] as? String) ?? 0
        let quarterTurns = DevicectlDisplays.anticlockwise(clockwise) / 90
        return IOSDevicePanel(
            width: size[0].doubleValue / scale,
            height: size[1].doubleValue / scale,
            scale: scale,
            orientation: OrientationCoordinateMath.Orientation(uprightQuarterTurnsCounterclockwise: quarterTurns)
        ).rebased(onPoints: IOSDevicePoints.parse(display: display, scale: scale))
    }

    /// The same panel measured in the UI's points, given in either order; the panel keeps its native axes, so the touchscreen's
    /// fractions stay fractions of the UI.
    public func rebased(onPoints points: IOSDevicePoints?) -> IOSDevicePanel {
        guard let points, points.width > 0, points.height > 0 else { return self }
        let long = max(points.width, points.height)
        let short = min(points.width, points.height)
        var panel = self
        panel.width = width >= height ? long : short
        panel.height = width >= height ? short : long
        return panel
    }

    /// The UI's size in points, swapped when the UI is sideways on the panel.
    public var uiWidth: Double { orientation.isLandscape ? height : width }
    public var uiHeight: Double { orientation.isLandscape ? width : height }

    /// A UI point as a point on the panel's native axes, the input space `InputEvent` carries for a device.
    public func panelPoint(x: Double, y: Double) -> (x: Double, y: Double) {
        OrientationCoordinateMath.translateToPhysical(x: x, y: y, orientation: orientation, portraitWidth: width, portraitHeight: height)
    }

    /// A panel point as the digitizer's fractions, clamped to the panel.
    public func fraction(x: Double, y: Double) -> (x: Double, y: Double) {
        (x: min(max(x / width, 0), 1), y: min(max(y / height, 0), 1))
    }
}

/// The UI's size in points: devicectl's `bounds` over `pointScale`, the framebuffer the UI renders into.
/// Display Zoom scales it away from `nativeSize` (an iPad Pro 13-inch at More Space renders 3200 x 2400 for a 2752 x 2064 panel).
public struct IOSDevicePoints: Codable, Equatable, Sendable {
    public var width: Double
    public var height: Double

    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }

    /// The display's `bounds` (`[[x, y], [width, height]]`) over its point scale; nil when either is missing or empty.
    static func parse(display: [String: Any], scale: Double) -> IOSDevicePoints? {
        guard scale > 0, let bounds = display["bounds"] as? [Any], bounds.count == 2, let size = bounds[1] as? [NSNumber], size.count == 2 else { return nil }
        let width = size[0].doubleValue / scale
        let height = size[1].doubleValue / scale
        guard width > 0, height > 0, width.isFinite, height.isFinite else { return nil }
        return IOSDevicePoints(width: width, height: height)
    }
}
