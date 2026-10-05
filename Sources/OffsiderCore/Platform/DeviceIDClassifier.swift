import Foundation

public enum DeviceIDClassification: Equatable, Sendable {
    case empty
    /// Canonical uppercase UUID, so lookups ignore the case the caller typed.
    case iosSimulator(udid: String)
    /// A physical iPhone or iPad: `00008130-001C...` in uppercase, or a 40-hex UDID in lowercase.
    case iosDevice(udid: String)
    case androidSerial(consolePort: Int)
    /// An AVD name or a USB phone's serial; the router resolves which.
    case androidName(name: String)
    /// A Wi-Fi or TCP adb connection (`host:port` or an mDNS service name), which Offsider refuses.
    case androidNetworkSerial(serial: String)
    case unrecognised

    public var platform: DevicePlatform? {
        switch self {
        case .iosSimulator, .iosDevice:
            return .ios
        case .androidSerial, .androidName, .androidNetworkSerial:
            return .android
        case .empty, .unrecognised:
            return nil
        }
    }
}

public enum DeviceIDClassifier {
    private static let serialPrefix = "emulator-"
    private static let mdnsSuffixes = ["._adb-tls-connect._tcp", "._adb._tcp"]
    private static let avdNameCharacters = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-")

    public static func classify(_ raw: String) -> DeviceIDClassification {
        let id = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if id.isEmpty {
            return .empty
        }
        if let uuid = UUID(uuidString: id) {
            return .iosSimulator(udid: uuid.uuidString)
        }
        if let udid = physicalIOSUDID(id) {
            return .iosDevice(udid: udid)
        }
        if let port = consolePort(in: id) {
            return .androidSerial(consolePort: port)
        }
        if isNetworkSerial(id) {
            return .androidNetworkSerial(serial: id)
        }
        if id.unicodeScalars.allSatisfy(avdNameCharacters.contains) {
            return .androidName(name: id)
        }
        return .unrecognised
    }

    private static func physicalIOSUDID(_ id: String) -> String? {
        let scalars = Array(id.unicodeScalars)
        let isHex: (Unicode.Scalar) -> Bool = { $0.isASCII && $0.properties.isASCIIHexDigit }
        if scalars.count == 25, scalars[8] == "-",
           scalars[..<8].allSatisfy(isHex), scalars[9...].allSatisfy(isHex) {
            return id.uppercased()
        }
        if scalars.count == 40, scalars.allSatisfy(isHex) {
            return id.lowercased()
        }
        return nil
    }

    private static func consolePort(in id: String) -> Int? {
        guard id.hasPrefix(serialPrefix) else { return nil }
        let digits = id.dropFirst(serialPrefix.count)
        guard !digits.isEmpty, digits.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return Int(digits)
    }

    private static func isNetworkSerial(_ id: String) -> Bool {
        if mdnsSuffixes.contains(where: id.hasSuffix) {
            return true
        }
        guard let colon = id.lastIndex(of: ":"), colon != id.startIndex, !id.contains(where: \.isWhitespace) else { return false }
        let port = id[id.index(after: colon)...]
        return !port.isEmpty && port.allSatisfy { $0.isASCII && $0.isNumber }
    }
}
