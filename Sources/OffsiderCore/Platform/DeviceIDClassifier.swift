import Foundation

public enum DeviceIDClassification: Equatable, Sendable {
    case empty
    /// Canonical uppercase UUID, so lookups ignore the case the caller typed.
    case iosSimulator(udid: String)
    case androidSerial(consolePort: Int)
    case androidAVDCandidate(name: String)
    case unrecognised

    public var platform: DevicePlatform? {
        switch self {
        case .iosSimulator:
            return .ios
        case .androidSerial, .androidAVDCandidate:
            return .android
        case .empty, .unrecognised:
            return nil
        }
    }
}

public enum DeviceIDClassifier {
    private static let serialPrefix = "emulator-"
    private static let avdNameCharacters = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-")

    public static func classify(_ raw: String) -> DeviceIDClassification {
        let id = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if id.isEmpty {
            return .empty
        }
        if let uuid = UUID(uuidString: id) {
            return .iosSimulator(udid: uuid.uuidString)
        }
        if let port = consolePort(in: id) {
            return .androidSerial(consolePort: port)
        }
        if id.unicodeScalars.allSatisfy(avdNameCharacters.contains) {
            return .androidAVDCandidate(name: id)
        }
        return .unrecognised
    }

    private static func consolePort(in id: String) -> Int? {
        guard id.hasPrefix(serialPrefix) else { return nil }
        let digits = id.dropFirst(serialPrefix.count)
        guard !digits.isEmpty, digits.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return Int(digits)
    }
}
