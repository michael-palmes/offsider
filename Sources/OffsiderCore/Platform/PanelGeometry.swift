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

    /// How SpringBoard's frames differ from the screen's here; nil when they agree.
    public var turn: PanelTurn? {
        PanelTurn(orientation: orientation, panelWidth: display.pointWidth, panelHeight: display.pointHeight)
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

/// SpringBoard lays out in the panel's own points however the UI is turned, so its alerts and home screen need turning to the screen points input and captures use.
public struct PanelTurn: Equatable, Sendable {
    public let orientation: OrientationCoordinateMath.Orientation
    public let panelWidth: Double
    public let panelHeight: Double

    /// Nil when the UI sits upright on the panel, so the two agree.
    public init?(orientation: OrientationCoordinateMath.Orientation, panelWidth: Double, panelHeight: Double) {
        guard orientation != .portrait else { return nil }
        self.orientation = orientation
        self.panelWidth = panelWidth
        self.panelHeight = panelHeight
    }

    /// A screen point in the panel's points, where SpringBoard answers a point read.
    public func panelPoint(_ point: UIPoint) -> UIPoint {
        let panel = OrientationCoordinateMath.translateToPhysical(x: point.x, y: point.y, orientation: orientation, portraitWidth: panelWidth, portraitHeight: panelHeight)
        return UIPoint(x: panel.x, y: panel.y)
    }

    /// A frame in the panel's points, in screen points.
    public func screenFrame(_ frame: UIFrame) -> UIFrame {
        switch orientation {
        case .portrait:
            return frame
        case .portraitUpsideDown:
            return UIFrame(x: panelWidth - frame.x - frame.width, y: panelHeight - frame.y - frame.height, width: frame.width, height: frame.height)
        case .landscape:
            return UIFrame(x: panelHeight - frame.y - frame.height, y: frame.x, width: frame.height, height: frame.width)
        case .landscapeFlipped:
            return UIFrame(x: frame.y, y: panelWidth - frame.x - frame.width, width: frame.height, height: frame.width)
        }
    }

    /// `roots` in screen points; an application root is the whole screen, whichever display its frame named.
    public func screenRoots(_ roots: [UINode]) -> [UINode] {
        let screen = orientation.isLandscape ? (width: panelHeight, height: panelWidth) : (width: panelWidth, height: panelHeight)
        func turned(_ node: UINode, isRoot: Bool) -> UINode {
            var node = node
            node.frame = isRoot && node.role == .application ? UIFrame(x: 0, y: 0, width: screen.width, height: screen.height) : node.frame.map(screenFrame)
            node.children = node.children.map { turned($0, isRoot: false) }
            return node
        }
        return roots.map { turned($0, isRoot: true) }
    }
}
