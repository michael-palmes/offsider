import Foundation

/// The progress value `slider` sends for a fraction of a node's own range, whatever units the app uses.
enum SliderMath {
    /// `min + fraction * (max - min)`, rounded for "int" ranges because `AbsSeekBar` truncates; `reachable` is what it shows.
    static func target(fraction: Double, range: HelperRange) -> (value: Double, reachable: Double) {
        let clamped = min(max(fraction, 0), 1)
        let span = range.max - range.min
        var value = range.min + clamped * span
        if range.type == "int" {
            value = value.rounded()
        }
        return (value, span > 0 ? (value - range.min) / span : 0)
    }
}
