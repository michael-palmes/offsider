import Foundation
import OffsiderCore

enum AdbDeviceState: Equatable, Sendable {
    case device
    case offline
    case unauthorized
    case other(String)

    init(_ text: String) {
        switch text {
        case "device": self = .device
        case "offline": self = .offline
        case "unauthorized": self = .unauthorized
        default: self = .other(text)
        }
    }
}

struct AdbDeviceEntry: Equatable, Sendable {
    let serial: String
    let state: AdbDeviceState
    /// `product`, `model`, `device`, `transport_id` and any other `key:value` pairs.
    let properties: [String: String]

    /// Only `emulator-NNNN` serials name a console port; USB and `host:port` serials do not.
    var consolePort: Int? {
        guard case .androidSerial(let port) = DeviceIDClassifier.classify(serial) else { return nil }
        return port
    }
}

enum AdbDeviceListParser {
    /// `host:devices-l` rows: serial, state, then `key:value` pairs; blank and malformed lines are skipped.
    static func parse(_ text: String) -> [AdbDeviceEntry] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard fields.count >= 2 else { return nil }
            var properties: [String: String] = [:]
            for field in fields.dropFirst(2) {
                guard let colon = field.firstIndex(of: ":"), colon != field.startIndex else { continue }
                properties[String(field[..<colon])] = String(field[field.index(after: colon)...])
            }
            return AdbDeviceEntry(serial: fields[0], state: AdbDeviceState(fields[1]), properties: properties)
        }
    }
}
