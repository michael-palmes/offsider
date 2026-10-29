import Foundation

public enum GesturePreset: String, CaseIterable, Sendable {
    case scrollUp = "scroll-up"
    case scrollDown = "scroll-down"
    case scrollLeft = "scroll-left"
    case scrollRight = "scroll-right"
    case swipeFromLeftEdge = "swipe-from-left-edge"
    case swipeFromRightEdge = "swipe-from-right-edge"
    case swipeFromTopEdge = "swipe-from-top-edge"
    case swipeFromTopRightEdge = "swipe-from-top-right-edge"
    case swipeFromBottomEdge = "swipe-from-bottom-edge"
    case longPressDrag = "long-press-drag"
    case pinch

    public enum Kind: Sendable {
        /// A swipe sized to the screen.
        case swipe
        /// A held press then a drag between points the caller gives.
        case longPressDrag
        /// Two fingers moving apart or together about a centre.
        case pinch
    }

    public var kind: Kind {
        switch self {
        case .longPressDrag: return .longPressDrag
        case .pinch: return .pinch
        default: return .swipe
        }
    }

    public static var swipes: [GesturePreset] { allCases.filter { $0.kind == .swipe } }

    /// Top and bottom swipes are system gestures at the screen's edge; left and right drive an app's own back swipe at its window's edge.
    public var spansScreen: Bool {
        switch self {
        case .swipeFromTopEdge, .swipeFromTopRightEdge, .swipeFromBottomEdge: return true
        case .swipeFromLeftEdge, .swipeFromRightEdge, .scrollUp, .scrollDown, .scrollLeft, .scrollRight, .longPressDrag, .pinch: return false
        }
    }

    /// How long `long-press-drag` holds before it moves, in milliseconds.
    public static let defaultHoldMilliseconds = 800
    /// Moves in a `long-press-drag`.
    public static let dragSteps = 60

    /// How far left and right edge swipes start inside the screen edge, and stop short of the far one, in points.
    public static let edgeMargin = 20.0
    /// How far top and bottom edge swipes start inside the screen edge, in points; system edge gestures need the very edge.
    public static let verticalEdgeInset = 2.0
    /// Where the top presets start across the width: Notification Centre on the left, Control Centre on the right.
    public static let topEdgeFraction = 0.25
    public static let topRightEdgeFraction = 0.8
    /// Where top presets stop, and bottom presets stop, down the height.
    public static let topEdgeEndFraction = 0.7
    public static let bottomEdgeEndFraction = 0.3
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
            return "Swipe down from the top edge a quarter across (Notification Centre, Android's notification shade)"
        case .swipeFromTopRightEdge:
            return "Swipe down from the top edge near the right (Control Centre)"
        case .swipeFromBottomEdge:
            return "Swipe up from the bottom edge (Android's home gesture)"
        case .longPressDrag:
            return "Press and hold, then drag to another point"
        case .pinch:
            return "Two fingers move apart (zoom in) or together (zoom out)"
        }
    }

    public var defaultDuration: Double {
        switch self {
        case .scrollUp, .scrollDown, .scrollLeft, .scrollRight:
            return 0.5
        case .swipeFromTopEdge, .swipeFromTopRightEdge, .swipeFromBottomEdge:
            return 0.1
        case .swipeFromLeftEdge, .swipeFromRightEdge:
            return 0.2
        case .longPressDrag:
            return 0.6
        case .pinch:
            return 0.5
        }
    }

    public var defaultDelta: Double {
        switch self {
        case .scrollUp, .scrollDown, .scrollLeft, .scrollRight:
            return 25.0
        case .swipeFromLeftEdge, .swipeFromRightEdge, .swipeFromTopEdge, .swipeFromTopRightEdge, .swipeFromBottomEdge, .longPressDrag, .pinch:
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

    /// What the preset spans: top and bottom swipes the screen, else the viewport, else the app frame; the rest the app frame. Nil when none is known.
    public func frame(screen: UISize?, viewport: UIFrame?, applicationFrame: UIFrame?, width: Double?, height: Double?) -> UIFrame? {
        let screenFrame = screen.flatMap { $0.width > 0 && $0.height > 0 ? UIFrame(x: 0, y: 0, width: $0.width, height: $0.height) : nil }
        let base = spansScreen ? screenFrame ?? viewport ?? applicationFrame : applicationFrame
        return base.map { Self.screen(applicationFrame: $0, width: width, height: height) }
    }

    /// Start and end points in `screen`, in the logical points of its current orientation; `long-press-drag` takes its points from the caller.
    public func endpoints(in screen: UIFrame) -> (start: UIPoint, end: UIPoint) {
        let minX = screen.x + Self.edgeMargin
        let maxX = screen.x + screen.width - Self.edgeMargin
        let topY = screen.y + Self.verticalEdgeInset
        let bottomY = screen.y + screen.height - Self.verticalEdgeInset
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
        case .swipeFromTopEdge, .swipeFromTopRightEdge:
            let x = screen.x + screen.width * (self == .swipeFromTopEdge ? Self.topEdgeFraction : Self.topRightEdgeFraction)
            return (UIPoint(x: x, y: topY), UIPoint(x: x, y: screen.y + screen.height * Self.topEdgeEndFraction))
        case .swipeFromBottomEdge:
            return (UIPoint(x: centerX, y: bottomY), UIPoint(x: centerX, y: screen.y + screen.height * Self.bottomEdgeEndFraction))
        case .longPressDrag, .pinch:
            return (UIPoint(x: centerX, y: centerY), UIPoint(x: centerX, y: centerY))
        }
    }

    // MARK: Pinch

    /// Points between the two fingers at the start or end of a pinch.
    public static let pinchSpreads: ClosedRange<Double> = 20...600
    public static let pinchDurations: ClosedRange<Double> = 0.1...10

    /// About 60 moves a second, so a pinch reads as smooth to a gesture recogniser, from 10 to 240.
    public static func pinchMoves(duration: Double) -> Int {
        min(240, max(10, Int((duration * 60).rounded())))
    }

    /// The fingers left then right of `centre` on a horizontal line, from `from` to `to` points apart; the first and last frames are the spreads themselves.
    public static func pinchFrames(centre: UIPoint, from: Double, to: Double, moves: Int) -> [(UIPoint, UIPoint)] {
        (0...max(1, moves)).map { step in
            let spread = from + (to - from) * Double(step) / Double(max(1, moves))
            return (UIPoint(x: centre.x - spread / 2, y: centre.y), UIPoint(x: centre.x + spread / 2, y: centre.y))
        }
    }
}
