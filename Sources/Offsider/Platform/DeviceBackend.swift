import Foundation

enum DevicePlatform: String, Sendable {
    case ios
    case android
}

struct DeviceID: Hashable, Sendable, CustomStringConvertible {
    let rawValue: String
    let platform: DevicePlatform

    var description: String { rawValue }
}
