import Foundation

/// Measured on emulator 37.1.11: `sendTouch` takes the panel's natural portrait pixels whoever rotated the display,
/// and `getScreenshot` turns with the emulator, not the guest.
enum PanelRotation {
    /// A point in logical pixels at the guest's current rotation, rounded and clamped to the natural W x H panel.
    static func panelPoint(_ point: AndroidPoint, rotation: Int, naturalWidth: Int, naturalHeight: Int) -> (x: Int32, y: Int32) {
        let x = Int(point.x.rounded())
        let y = Int(point.y.rounded())
        let width = naturalWidth
        let height = naturalHeight
        let panel: (Int, Int)
        switch rotation {
        case 1: panel = (width - 1 - y, x)
        case 2: panel = (width - 1 - x, height - 1 - y)
        case 3: panel = (y, height - 1 - x)
        default: panel = (x, y)
        }
        return (Int32(min(max(panel.0, 0), width - 1)), Int32(min(max(panel.1, 0), height - 1)))
    }

    /// Counterclockwise quarter turns that make an emulator frame match the guest.
    static func screenshotTurns(guestRotation: Int, emulatorRotation: Int) -> Int {
        ((guestRotation - emulatorRotation) % 4 + 4) % 4
    }
}
