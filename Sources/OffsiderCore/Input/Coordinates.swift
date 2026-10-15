/// The one range every coordinate, delta and distance a person gives must fall in, on every platform.
public enum Coordinates {
    /// The Android helper's own limit, so a value it would refuse never reaches a device.
    public static let limit: Double = 100_000

    /// The first named value that is not finite or lies outside -`limit`...`limit`, as one usage line; nil when all fit.
    public static func problem(_ values: [(name: String, value: Double?)]) -> String? {
        for (name, value) in values {
            guard let value else { continue }
            if !value.isFinite || abs(value) > limit {
                return "\(name) must be a number from -100000 to 100000; got \(value)."
            }
        }
        return nil
    }

    /// Whether `value` is finite and within -`limit`...`limit`.
    public static func fits(_ value: Double) -> Bool {
        value.isFinite && abs(value) <= limit
    }
}
