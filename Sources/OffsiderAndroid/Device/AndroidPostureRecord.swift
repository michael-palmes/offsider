import Foundation
import OffsiderCore

/// The device-state override Offsider set on a USB phone, kept until `posture reset`, `session stop` or `devices remove` takes it off.
struct AndroidPostureRecord: AndroidSerialRecord, Equatable, Sendable {
    static let maximumBytes = 1_024
    static let directoryName = "postures"
    static let bootIDScript = "cat /proc/sys/kernel/random/boot_id"

    let serial: String
    /// The phone's kernel boot id: an override ends with a reboot, so a record from an earlier boot is stale.
    let bootID: String
    let identifier: Int

    /// Named as the display cache names a phone, so a serial never reaches a file name.
    static func fileName(serial: String) -> String {
        AndroidDisplayCacheEntry.fileName(serial: serial)
    }

    /// A boot id is a UUID; anything else is not one this phone printed.
    static func isBootID(_ text: String) -> Bool {
        text.count == 36 && text.unicodeScalars.allSatisfy { CharacterSet(charactersIn: "0123456789abcdef-").contains($0) }
    }

    func encoded() -> Data {
        let object: [String: Any] = ["serial": serial, "bootID": bootID, "identifier": identifier]
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
    }

    init(serial: String, bootID: String, identifier: Int) {
        self.serial = serial
        self.bootID = bootID
        self.identifier = identifier
    }

    init?(data: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let serial = object["serial"] as? String, let bootID = object["bootID"] as? String, Self.isBootID(bootID),
              let identifier = (object["identifier"] as? NSNumber)?.intValue else { return nil }
        self.init(serial: serial, bootID: bootID, identifier: identifier)
    }
}

/// A record of what Offsider changed on one device, kept in one private file named by a hash of its serial.
protocol AndroidSerialRecord {
    static var maximumBytes: Int { get }
    var serial: String { get }
    func encoded() -> Data
    init?(data: Data)
}

typealias AndroidPostureRecordStore = AndroidSerialRecordStore<AndroidPostureRecord>

struct AndroidSerialRecordStore<Record: AndroidSerialRecord> {
    /// A record this old for a device not seen since is dropped rather than named on every stop.
    static var forgottenAfter: TimeInterval { 30 * 86_400 }

    let directory: String

    /// Whether the record's file was last written over `forgottenAfter` before `now`.
    func isForgotten(serial: String, now: Date = Date()) -> Bool {
        let path = (directory as NSString).appendingPathComponent(AndroidPostureRecord.fileName(serial: serial))
        guard let written = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date else { return false }
        return now.timeIntervalSince(written) > Self.forgottenAfter
    }

    /// The record for `serial`, or nil; a corrupt or foreign one is removed, and one that cannot be read safely is left and reads as none.
    func load(serial: String) -> Record? {
        let name = AndroidPostureRecord.fileName(serial: serial)
        guard let data = try? OffsiderPrivateDirectory.readOwnedFile(named: name, in: directory, maxBytes: Record.maximumBytes) else { return nil }
        guard let record = Record(data: data), record.serial == serial else {
            OffsiderPrivateDirectory.removeFile(named: name, in: directory)
            return nil
        }
        return record
    }

    /// Every record, under the same rules as `load`.
    func all() -> [Record] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
        return names.filter { $0.hasSuffix(".json") }.sorted().compactMap { name in
            guard let data = try? OffsiderPrivateDirectory.readOwnedFile(named: name, in: directory, maxBytes: Record.maximumBytes) else { return nil }
            guard let record = Record(data: data), AndroidPostureRecord.fileName(serial: record.serial) == name else {
                OffsiderPrivateDirectory.removeFile(named: name, in: directory)
                return nil
            }
            return record
        }
    }

    func save(_ record: Record) throws {
        try OffsiderPrivateDirectory.writeAtomically(record.encoded(), named: AndroidPostureRecord.fileName(serial: record.serial), in: directory)
    }

    func remove(serial: String) {
        OffsiderPrivateDirectory.removeFile(named: AndroidPostureRecord.fileName(serial: serial), in: directory)
    }
}
