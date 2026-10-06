/// Screen edges whose pixels change on their own (clock, status icons, navigation bar), in points or dp.
public struct ScreenBands: Equatable, Sendable {
    public let top: Double
    public let bottom: Double
    /// True when the bands sit on the UI's top and bottom in every orientation; otherwise they are left out in portrait only.
    public let everyOrientation: Bool
    /// Counterclockwise quarter turns that make the backend's raw screenshot upright, so the bands can be placed on it.
    public let screenshotQuarterTurns: Int
    /// How far a still screen's colours drift between lossy captures (video frames); 0 when captures are exact.
    public let noiseTolerance: Int

    public init(top: Double, bottom: Double, everyOrientation: Bool = false, screenshotQuarterTurns: Int = 0, noiseTolerance: Int = 0) {
        self.top = top
        self.bottom = bottom
        self.everyOrientation = everyOrientation
        self.screenshotQuarterTurns = screenshotQuarterTurns
        self.noiseTolerance = noiseTolerance
    }

    /// The bands on a raw screenshot's edges, in that screenshot's pixels; the UI's top is the edge the upright turn brings to the top.
    public func screenshotPixels(scale: Double) -> (top: Int, bottom: Int, left: Int, right: Int) {
        let top = Int((self.top * scale).rounded())
        let bottom = Int((self.bottom * scale).rounded())
        switch (screenshotQuarterTurns % 4 + 4) % 4 {
        case 1: return (0, 0, bottom, top)
        case 2: return (bottom, top, 0, 0)
        case 3: return (0, 0, top, bottom)
        default: return (top, bottom, 0, 0)
        }
    }
}
