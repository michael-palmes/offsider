/// Screen edges whose pixels change on their own (clock, status icons, navigation bar), in points or dp.
public struct ScreenBands: Equatable, Sendable {
    public let top: Double
    public let bottom: Double

    public init(top: Double, bottom: Double) {
        self.top = top
        self.bottom = bottom
    }
}
