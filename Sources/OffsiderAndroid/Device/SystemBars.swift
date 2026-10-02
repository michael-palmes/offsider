import Foundation
import OffsiderCore

/// The status and navigation bars `--verify` leaves out of screenshots, measured from the helper's window list.
enum SystemBars {
    /// The status bar with its cutout (54 dp on a Pixel 9) and a three-button navigation bar, when nothing was measured.
    static let fallback = ScreenBands(top: 60, bottom: 48)

    /// System windows spanning at least 90 % of the width and at most 25 % of the height, touching the top or bottom edge, in dp.
    static func bands(windows: [HelperWindow], display: HelperDisplay) -> ScreenBands {
        let width = Double(display.logicalWidthPx)
        let height = Double(display.logicalHeightPx)
        let scale = Double(display.densityDpi) / 160
        guard width > 0, height > 0, scale > 0 else { return fallback }
        var top = 0.0
        var bottom = 0.0
        for window in windows where window.type == "system" && window.bounds.count == 4 {
            let left = Double(window.bounds[0]), upper = Double(window.bounds[1])
            let right = Double(window.bounds[2]), lower = Double(window.bounds[3])
            guard right - left >= 0.9 * width, lower > upper, lower - upper <= 0.25 * height else { continue }
            if upper <= 0 {
                top = max(top, lower)
            } else if lower >= height {
                bottom = max(bottom, height - upper)
            }
        }
        return ScreenBands(top: dp(top / scale), bottom: dp(bottom / scale))
    }

    private static func dp(_ value: Double) -> Double {
        (value * 100).rounded() / 100
    }
}
