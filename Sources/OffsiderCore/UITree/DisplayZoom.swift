import Foundation

/// iOS Display Zoom: the accessibility tree is in a smaller layout space, while input and captures use the screen's points.
public struct DisplayZoom: Equatable, Sendable {
    private static let originTolerance = 1.0
    /// The gentlest real zoom is a Plus phone's 414 to 375 pt, about 1.1.
    private static let smallestScale = 1.05
    /// The two axes scale up to about 0.2% apart.
    private static let shapeTolerance = 0.015

    let scaleX: Double
    let scaleY: Double

    /// Nil unless the application root is smaller than the screen, in its shape and from its corner, which a window never is; either way round, as a turned phone's frame is.
    public init?(in roots: [UINode], screenWidth: Double, screenHeight: Double) {
        guard let frame = roots.first(where: { $0.role == .application })?.frame,
              abs(frame.x) <= Self.originTolerance, abs(frame.y) <= Self.originTolerance,
              frame.width > 0, frame.height > 0, screenWidth > 0, screenHeight > 0 else { return nil }
        let wide = frame.width > frame.height
        let scaleX = (wide ? max(screenWidth, screenHeight) : min(screenWidth, screenHeight)) / frame.width
        let scaleY = (wide ? min(screenWidth, screenHeight) : max(screenWidth, screenHeight)) / frame.height
        guard scaleX >= Self.smallestScale, scaleY >= Self.smallestScale, abs(scaleX / scaleY - 1) <= Self.shapeTolerance else { return nil }
        self.scaleX = scaleX
        self.scaleY = scaleY
    }

    /// Screen points to the layout space a hit-test reads.
    public func layoutPoint(_ point: UIPoint) -> UIPoint {
        UIPoint(x: point.x / scaleX, y: point.y / scaleY)
    }

    /// Every frame in screen points, to a hundredth, so two reads of one element still match.
    public func screenRoots(_ roots: [UINode]) -> [UINode] {
        roots.map { node in
            var scaled = node
            scaled.frame = node.frame.map { frame in
                UIFrame(
                    x: Self.rounded(frame.x * scaleX), y: Self.rounded(frame.y * scaleY),
                    width: Self.rounded(frame.width * scaleX), height: Self.rounded(frame.height * scaleY)
                )
            }
            scaled.children = screenRoots(node.children)
            return scaled
        }
    }

    private static func rounded(_ value: Double) -> Double {
        (value * 100).rounded() / 100
    }
}
