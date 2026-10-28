import CryptoKit
import Foundation

/// `adb reverse` for Metro on a USB Android phone: only `tcp:<port> tcp:<port>`, only on a port a person allowed, recorded so `session stop` removes Offsider's own and no other.
public enum MetroReverse {
    public static let lowestPort = 1024
    /// adb's server, and each emulator's console, adb and gRPC ports: never mapped, whatever answers on them.
    static let reserved: [ClosedRange<Int>] = [5037...5037, 5554...5682, 8554...8682]

    /// Why `port` can never be a Metro port, or nil.
    public static func refusal(port: Int) -> String? {
        guard (lowestPort...65_535).contains(port) else { return "A Metro port is from \(lowestPort) to 65535, and \(port) is not." }
        guard !reserved.contains(where: { $0.contains(port) }) else { return "Port \(port) belongs to adb or an emulator, never Metro." }
        return nil
    }

    /// `norebind`, so a reverse someone set meanwhile is refused rather than replaced.
    public static func addService(port: Int) -> String {
        "reverse:forward:norebind:tcp:\(port);tcp:\(port)"
    }

    public static func removeService(port: Int) -> String {
        "reverse:killforward:tcp:\(port)"
    }

    /// Each `reverse:list-forward` line (`<serial> tcp:8081 tcp:8081`) as its phone side and Mac side.
    public static func mappings(_ listing: String) -> [(phone: String, mac: String)] {
        listing.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count >= 3 else { return nil }
            return (String(fields[1]), String(fields[2]))
        }
    }

    /// Whether some reverse listens on the phone's `tcp:<port>`, whatever it maps to.
    public static func phoneListens(_ listing: String, port: Int) -> Bool {
        mappings(listing).contains { $0.phone == "tcp:\(port)" }
    }

    /// Whether a reverse maps the phone's `tcp:<port>` to the same port on the Mac, as Offsider sets them.
    public static func mapsSamePort(_ listing: String, port: Int) -> Bool {
        mappings(listing).contains { $0.phone == "tcp:\(port)" && $0.mac == "tcp:\(port)" }
    }
}

/// The reverses Offsider set on one phone during one adb connection, kept in the private `reverses/`.
public struct MetroReverseRecord: Equatable, Sendable {
    public static let version = 1
    public static let maximumBytes = 4_096
    public static let directoryName = "reverses"

    public var serial: String
    /// adb's `transport_id` for the connection the reverses were set on; a reverse ends with its connection.
    public var transportId: String
    public var ports: [Int]

    public init(serial: String, transportId: String, ports: [Int]) {
        self.serial = serial
        self.transportId = transportId
        self.ports = ports
    }

    /// `<first 16 hex of SHA-256 of "android:serial">.json`, so a serial never reaches a file name.
    public static func fileName(serial: String) -> String {
        let digest = SHA256.hash(data: Data("android:\(serial)".utf8))
        return digest.prefix(8).map { unsafe String(format: "%02x", $0) }.joined() + ".json"
    }

    public func encoded() -> Data {
        let object: [String: Any] = ["version": Self.version, "serial": serial, "transportId": transportId, "ports": ports]
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
    }

    /// Nil for anything malformed, another version, or a port that could never be a Metro port.
    public init?(data: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (object["version"] as? NSNumber)?.intValue == Self.version,
              let serial = object["serial"] as? String, !serial.isEmpty,
              let transportId = object["transportId"] as? String, !transportId.isEmpty,
              let ports = object["ports"] as? [NSNumber], ports.count <= DeviceAllowance.maximumMetroPorts else { return nil }
        let numbers = ports.compactMap { Int(exactly: $0.doubleValue) }
        guard numbers.count == ports.count, numbers.allSatisfy({ MetroReverse.refusal(port: $0) == nil }) else { return nil }
        self.init(serial: serial, transportId: transportId, ports: numbers)
    }
}

/// `MetroReverseRecord`s in one private directory, one file per phone.
public struct MetroReverseStore: Sendable {
    public let directory: String

    public init(directory: String) {
        self.directory = directory
    }

    /// Nil when there is none, or it cannot be read or trusted.
    public func load(serial: String) -> MetroReverseRecord? {
        let name = MetroReverseRecord.fileName(serial: serial)
        guard let data = try? OffsiderPrivateDirectory.readOwnedFile(named: name, in: directory, maxBytes: MetroReverseRecord.maximumBytes),
              let record = MetroReverseRecord(data: data), record.serial == serial else { return nil }
        return record
    }

    /// Every phone's record that can be read, by serial.
    public func all() -> [MetroReverseRecord] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
        return names.sorted().compactMap { name in
            guard name.hasSuffix(".json"), !name.hasPrefix("."),
                  let data = try? OffsiderPrivateDirectory.readOwnedFile(named: name, in: directory, maxBytes: MetroReverseRecord.maximumBytes),
                  let record = MetroReverseRecord(data: data), MetroReverseRecord.fileName(serial: record.serial) == name else { return nil }
            return record
        }
    }

    /// Writes the record, or removes its file once no port is left.
    public func save(_ record: MetroReverseRecord) throws {
        let name = MetroReverseRecord.fileName(serial: record.serial)
        guard !record.ports.isEmpty else {
            OffsiderPrivateDirectory.removeFile(named: name, in: directory)
            return
        }
        try OffsiderPrivateDirectory.writeAtomically(record.encoded(), named: name, in: directory)
    }
}
