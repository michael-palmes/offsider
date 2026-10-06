import Foundation

public enum GesturePreset: String, CaseIterable, Sendable {
    case scrollUp = "scroll-up"
    case scrollDown = "scroll-down"
    case scrollLeft = "scroll-left"
    case scrollRight = "scroll-right"
    case swipeFromLeftEdge = "swipe-from-left-edge"
    case swipeFromRightEdge = "swipe-from-right-edge"
    case swipeFromTopEdge = "swipe-from-top-edge"
    case swipeFromBottomEdge = "swipe-from-bottom-edge"
    case longPressDrag = "long-press-drag"

    public enum Kind: Sendable {
        /// A swipe sized to the screen.
        case swipe
        /// A held press then a drag between points the caller gives.
        case longPressDrag
    }

    public var kind: Kind {
        self == .longPressDrag ? .longPressDrag : .swipe
    }

    public static var swipes: [GesturePreset] { allCases.filter { $0.kind == .swipe } }

    /// How long `long-press-drag` holds before it moves, in milliseconds.
    public static let defaultHoldMilliseconds = 800
    /// Moves in a `long-press-drag`.
    public static let dragSteps = 60

    /// How far edge swipes start inside the screen edge, in points.
    public static let edgeMargin = 20.0
    /// Length of the scroll presets, in points.
    public static let scrollDistance = 200.0

    public var description: String {
        switch self {
        case .scrollUp:
            return "Scroll up in the center of screen"
        case .scrollDown:
            return "Scroll down in the center of screen"
        case .scrollLeft:
            return "Scroll left in the center of screen"
        case .scrollRight:
            return "Scroll right in the center of screen"
        case .swipeFromLeftEdge:
            return "Swipe from left edge to center (back navigation)"
        case .swipeFromRightEdge:
            return "Swipe from right edge to center (forward navigation)"
        case .swipeFromTopEdge:
            return "Swipe from top edge downward"
        case .swipeFromBottomEdge:
            return "Swipe from bottom edge upward"
        case .longPressDrag:
            return "Press and hold, then drag to another point"
        }
    }

    public var defaultDuration: Double {
        switch self {
        case .scrollUp, .scrollDown, .scrollLeft, .scrollRight:
            return 0.5
        case .swipeFromLeftEdge, .swipeFromRightEdge, .swipeFromTopEdge, .swipeFromBottomEdge:
            return 0.3
        case .longPressDrag:
            return 0.6
        }
    }

    public var defaultDelta: Double {
        switch self {
        case .scrollUp, .scrollDown, .scrollLeft, .scrollRight:
            return 25.0
        case .swipeFromLeftEdge, .swipeFromRightEdge, .swipeFromTopEdge, .swipeFromBottomEdge, .longPressDrag:
            return 50.0
        }
    }

    /// The app frame, with an explicit width or height in place of its own.
    public static func screen(applicationFrame: UIFrame, width: Double?, height: Double?) -> UIFrame {
        UIFrame(
            x: applicationFrame.x,
            y: applicationFrame.y,
            width: width ?? applicationFrame.width,
            height: height ?? applicationFrame.height
        )
    }

    /// Start and end points in `screen`, in the logical points of its current orientation; `long-press-drag` takes its points from the caller.
    public func endpoints(in screen: UIFrame) -> (start: UIPoint, end: UIPoint) {
        let minX = screen.x + Self.edgeMargin
        let maxX = screen.x + screen.width - Self.edgeMargin
        let minY = screen.y + Self.edgeMargin
        let maxY = screen.y + screen.height - Self.edgeMargin
        let centerX = screen.x + screen.width / 2
        let centerY = screen.y + screen.height / 2
        let halfScroll = Self.scrollDistance / 2

        switch self {
        case .scrollUp:
            return (UIPoint(x: centerX, y: centerY + halfScroll), UIPoint(x: centerX, y: centerY - halfScroll))
        case .scrollDown:
            return (UIPoint(x: centerX, y: centerY - halfScroll), UIPoint(x: centerX, y: centerY + halfScroll))
        case .scrollLeft:
            return (UIPoint(x: centerX + halfScroll, y: centerY), UIPoint(x: centerX - halfScroll, y: centerY))
        case .scrollRight:
            return (UIPoint(x: centerX - halfScroll, y: centerY), UIPoint(x: centerX + halfScroll, y: centerY))
        case .swipeFromLeftEdge:
            return (UIPoint(x: minX, y: centerY), UIPoint(x: maxX, y: centerY))
        case .swipeFromRightEdge:
            return (UIPoint(x: maxX, y: centerY), UIPoint(x: minX, y: centerY))
        case .swipeFromTopEdge:
            return (UIPoint(x: centerX, y: minY), UIPoint(x: centerX, y: maxY))
        case .swipeFromBottomEdge:
            return (UIPoint(x: centerX, y: maxY), UIPoint(x: centerX, y: minY))
        case .longPressDrag:
            return (UIPoint(x: centerX, y: centerY), UIPoint(x: centerX, y: centerY))
        }
    }
}
