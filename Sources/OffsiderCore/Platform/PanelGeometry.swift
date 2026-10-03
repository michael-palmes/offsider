import Foundation

/// A display's UI as it sits on its panel: the framebuffer and the digitizer keep the panel's native axes, the UI turns on them.
public struct PanelGeometry: Equatable, Sendable {
    public var display: DisplayDescriptor
    /// The UI's turn on the panel, as SimulatorKit reads it for the display's screen.
    public var orientation: OrientationCoordinateMath.Orientation

    public init(display: DisplayDescriptor, orientation: OrientationCoordinateMath.Orientation) {
        self.display = display
        self.orientation = orientation
    }

    /// The panel's points, swapped when the UI is sideways on it.
    public var width: Double { orientation.isLandscape ? display.pointHeight : display.pointWidth }
    public var height: Double { orientation.isLandscape ? display.pointWidth : display.pointHeight }

    /// The UI's anticlockwise turn on the panel, for input mapping; reports use `deviceOrientation`'s degrees.
    public var panelRotationDegrees: Int { orientation.rotationDegrees }

    /// How the device is held: the UI's turn on the panel less the turn the panel is mounted at.
    public var deviceOrientation: DeviceOrientation? {
        DeviceOrientation(rotationDegrees: ((panelRotationDegrees - display.nativeOrientation) % 360 + 360) % 360)
    }

    /// A UI point as fractions of the panel's width and height, which is what the digitizer takes.
    public func panelFraction(x: Double, y: Double) -> (x: Double, y: Double) {
        let panel = OrientationCoordinateMath.translateToPhysical(
            x: x, y: y, orientation: orientation, portraitWidth: display.pointWidth, portraitHeight: display.pointHeight
        )
        return (x: panel.x / display.pointWidth, y: panel.y / display.pointHeight)
    }

    /// A UI point in the main screen's points, as idb divides them by the main screen to get the same fractions.
    public func mainScreenPoint(x: Double, y: Double, mainWidth: Double, mainHeight: Double) -> (x: Double, y: Double) {
        let fraction = panelFraction(x: x, y: y)
        return (x: fraction.x * mainWidth, y: fraction.y * mainHeight)
    }
}
