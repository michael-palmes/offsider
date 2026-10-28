import CryptoKit
import Foundation
import OffsiderCore

/// The device-state override Offsider set on a USB phone, kept until `posture reset`, `session stop` or `devices remove` takes it off.
struct AndroidPostureRecord: Equatable, Sendable {
    static let maximumBytes = 1_024
    static let directoryName = "postures"
    static let bootIDScript = "cat /proc/sys/kernel/random/boot_id"

    let serial: String
    /// The phone's kernel boot id: an override ends with a reboot, so a record from an earlier boot is stale.
    let bootID: String
    let identifier: Int
    let name: String

    /// `<first 16 hex of SHA-256 of "android:serial">.json`, so a serial never reaches a file name.
    static func fileName(serial: String) -> String {
        SHA256.hash(data: Data("android:\(serial)".utf8)).prefix(8).map { String(format: "%02x", $0) }.joined() + ".json"
    }

    /// A boot id is a UUID; anything else is not one this phone printed.
    static func isBootID(_ text: String) -> Bool {
        text.count == 36 && text.unicodeScalars.allSatisfy { CharacterSet(charactersIn: "0123456789abcdef-").contains($0) }
    }

    func encoded() -> Data {
        let object: [String: Any] = ["serial": serial, "bootID": bootID, "identifier": identifier, "name": name]
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
    }

    init(serial: String, bootID: String, identifier: Int, name: String) {
        self.serial = serial
        self.bootID = bootID
        self.identifier = identifier
        self.name = name
    }

    init?(data: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let serial = object["serial"] as? String, let bootID = object["bootID"] as? String, Self.isBootID(bootID),
              let identifier = (object["identifier"] as? NSNumber)?.intValue, let name = object["name"] as? String else { return nil }
        self.init(serial: serial, bootID: bootID, identifier: identifier, name: name)
    }
}

struct AndroidPostureRecordStore {
    let directory: String

    /// The record for `serial`, or nil; an unreadable or foreign one is removed.
    func load(serial: String) -> AndroidPostureRecord? {
        let name = AndroidPostureRecord.fileName(serial: serial)
        guard let data = try? OffsiderPrivateDirectory.readOwnedFile(named: name, in: directory, maxBytes: AndroidPostureRecord.maximumBytes) else { return nil }
        guard let record = AndroidPostureRecord(data: data), record.serial == serial else {
            OffsiderPrivateDirectory.removeFile(named: name, in: directory)
            return nil
        }
        return record
    }

    func all() -> [AndroidPostureRecord] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
        return names.filter { $0.hasSuffix(".json") }.compactMap { name in
            (try? OffsiderPrivateDirectory.readOwnedFile(named: name, in: directory, maxBytes: AndroidPostureRecord.maximumBytes))
                .flatMap { $0 }.flatMap(AndroidPostureRecord.init(data:))
                .flatMap { AndroidPostureRecord.fileName(serial: $0.serial) == name ? $0 : nil }
        }
    }

    func save(_ record: AndroidPostureRecord) throws {
        try OffsiderPrivateDirectory.writeAtomically(record.encoded(), named: AndroidPostureRecord.fileName(serial: record.serial), in: directory)
    }

    func remove(serial: String) {
        OffsiderPrivateDirectory.removeFile(named: AndroidPostureRecord.fileName(serial: serial), in: directory)
    }
}
