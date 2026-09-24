import Foundation

public enum TapDeliveryStyle: String, Codable, Sendable {
    case simulator
    case physical

    public var alternate: TapDeliveryStyle {
        self == .simulator ? .physical : .simulator
    }
}

public enum RetryPolicy {
    public static let allowedRetries = 0...3
    public static let defaultRetries = 1

    public static func attemptCount(retries: Int) -> Int {
        max(0, retries) + 1
    }

    /// Each tap retry switches style, so a style the target ignores is not simply repeated.
    public static func tapStyles(initial: TapDeliveryStyle, retries: Int) -> [TapDeliveryStyle] {
        (0..<attemptCount(retries: retries)).map { $0.isMultiple(of: 2) ? initial : initial.alternate }
    }
}
