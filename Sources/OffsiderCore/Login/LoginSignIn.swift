import Foundation

/// Where and when Offsider last signed a saved login in. What Offsider submitted, not what the app accepted.
public struct LoginSignIn: Equatable, Sendable {
    public var device: String
    public var platform: DevicePlatform
    public var since: Date
    /// Nil when either boot marker is unknown.
    public var restarted: Bool?

    public init(device: String, platform: DevicePlatform, since: Date, restarted: Bool?) {
        self.device = device
        self.platform = platform
        self.since = since
        self.restarted = restarted
    }
}
