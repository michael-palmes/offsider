import Foundation

public enum OrientationCoordinateMath {
    public enum Orientation: String, CaseIterable, Sendable {
        case portrait
        case portraitUpsideDown
        case landscape
        case landscapeFlipped

        public var isLandscape: Bool {
            self == .landscape || self == .landscapeFlipped
        }

        /// The orientation whose upright image needs `quarterTurns` counterclockwise turns of a native framebuffer.
        public init(uprightQuarterTurnsCounterclockwise quarterTurns: Int) {
            switch (quarterTurns % 4 + 4) % 4 {
            case 1: self = .landscapeFlipped
            case 2: self = .portraitUpsideDown
            case 3: self = .landscape
            default: self = .portrait
            }
        }
    }

    public static func translateToPhysical(
        x: Double,
        y: Double,
        orientation: Orientation,
        portraitWidth: Double,
        portraitHeight: Double
    ) -> (x: Double, y: Double) {
        switch orientation {
        case .portrait:
            return (x, y)

        case .portraitUpsideDown:
            return (x: portraitWidth - x, y: portraitHeight - y)

        case .landscape:
            return (x: y, y: portraitHeight - x)

        case .landscapeFlipped:
            return (x: portraitWidth - y, y: x)
        }
    }

    /// From a display's native points to idb's main-screen points, as idb sends touches as fractions of the main screen.
    public static func scaleToMainScreen(
        x: Double,
        y: Double,
        displayWidth: Double,
        displayHeight: Double,
        mainWidth: Double,
        mainHeight: Double
    ) -> (x: Double, y: Double) {
        (x: x * mainWidth / displayWidth, y: y * mainHeight / displayHeight)
    }

    public static func letterboxToPhysical(
        x: Double,
        y: Double,
        scale: Double,
        offsetX: Double,
        offsetY: Double
    ) -> (x: Double, y: Double) {
        return (
            x: offsetX + x * scale,
            y: offsetY + y * scale
        )
    }

    public static func letterboxParameters(
        logicalWidth: Double,
        logicalHeight: Double,
        physicalWidth: Double,
        physicalHeight: Double
    ) -> (scale: Double, offsetX: Double, offsetY: Double) {
        let scale = min(physicalWidth / logicalWidth, physicalHeight / logicalHeight)
        let offsetX = (physicalWidth - logicalWidth * scale) / 2
        let offsetY = (physicalHeight - logicalHeight * scale) / 2
        return (scale, offsetX, offsetY)
    }
}
