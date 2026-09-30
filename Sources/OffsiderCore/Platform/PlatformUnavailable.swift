import Foundation

/// Thrown by `prepare()` when a platform's toolchain is not installed at all (no Xcode, no Android SDK).
public struct PlatformUnavailable: LocalizedError, CustomStringConvertible, Equatable, Sendable {
    public let platform: DevicePlatform
    public let message: String

    public init(platform: DevicePlatform, message: String) {
        self.platform = platform
        self.message = message
    }

    public var errorDescription: String? { message }
    public var description: String { message }
}
