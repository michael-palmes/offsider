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

    /// A USB Android phone rather than an emulator, whose serials are `emulator-<port>`.
    public var isPhysicalAndroidDevice: Bool {
        guard platform == .android else { return false }
        if case .androidSerial = DeviceIDClassifier.classify(rawValue) { return false }
        return true
    }

    /// A physical iPhone or iPad rather than a simulator; both share the `ios` platform.
    public var isPhysicalIOSDevice: Bool {
        guard platform == .ios, case .iosDevice = DeviceIDClassifier.classify(rawValue) else { return false }
        return true
    }
}
