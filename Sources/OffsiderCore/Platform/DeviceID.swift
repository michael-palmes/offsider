import Foundation

public enum DevicePlatform: String, CaseIterable, Codable, Sendable {
    case ios
    case android
}

public struct DeviceID: Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String
    public let platform: DevicePlatform

    public init(rawValue: String, platform: DevicePlatform) {
        self.rawValue = rawValue
        self.platform = platform
    }

    public var description: String { rawValue }
}
