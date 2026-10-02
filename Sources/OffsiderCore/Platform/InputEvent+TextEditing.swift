import Foundation

extension InputEvent {
    /// Left GUI (Command): select all on iOS.
    public static let commandKey: UInt32 = 227
    /// Left Control: select all on Android.
    public static let controlKey: UInt32 = 224

    /// `modifier` down, `a`, `modifier` up, 50 ms, Backspace: clears the focused field where select-all works.
    public static func selectAllAndDelete(modifier: UInt32) -> InputEvent {
        .composite([
            .keyboard(direction: .down, keyCode: modifier),
            .shortKeyPress(4),
            .keyboard(direction: .up, keyCode: modifier),
            .delay(0.05),
            .shortKeyPress(42),
        ])
    }
}
