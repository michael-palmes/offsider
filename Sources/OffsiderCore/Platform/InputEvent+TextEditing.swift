import Foundation

extension InputEvent {
    /// Left GUI (Command): select all on iOS.
    public static let commandKey: UInt32 = 227
    /// Left Control: select all on Android.
    public static let controlKey: UInt32 = 224
    /// iOS can still be deleting when the first replacement character arrives.
    public static let iosClearSettle: TimeInterval = 0.2

    /// `modifier` down, `a`, `modifier` up, 50 ms, Backspace, then `settle` seconds when it is above zero.
    public static func selectAllAndDelete(modifier: UInt32, settle: TimeInterval = 0) -> InputEvent {
        var events: [InputEvent] = [
            .keyboard(direction: .down, keyCode: modifier),
            .shortKeyPress(4),
            .keyboard(direction: .up, keyCode: modifier),
            .delay(0.05),
            .shortKeyPress(42),
        ]
        if settle > 0 { events.append(.delay(settle)) }
        return .composite(events)
    }
}
