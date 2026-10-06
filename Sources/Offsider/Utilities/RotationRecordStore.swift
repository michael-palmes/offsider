import Darwin
import Foundation
import OffsiderCore

/// One record per Android serial under the private directory's `orientation/`: auto-rotate before Offsider first turned the device.
struct RotationRecordStore {
    var root: String = OffsiderPrivateDirectory.root

    static func fileName(serial: String) -> String {
        "android-" + String(serial.map { $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) ? $0 : "_" }) + ".ini"
    }

    private var directory: String { (root as NSString).appendingPathComponent(OffsiderPrivateDirectory.orientationDirectoryName) }

    func read(_ serial: String) -> RotationRecord? {
        guard let data = try? OffsiderPrivateDirectory.readOwnedFile(named: Self.fileName(serial: serial), in: directory, maxBytes: 1024) else { return nil }
        return RotationRecord.parse(String(decoding: data, as: UTF8.self))
    }

    func write(_ record: RotationRecord, serial: String) throws {
        let directory = try OffsiderPrivateDirectory.ensureSubdirectory(OffsiderPrivateDirectory.orientationDirectoryName, root: root)
        try OffsiderPrivateDirectory.writeAtomically(Data(record.fileContents.utf8), named: Self.fileName(serial: serial), in: directory)
    }

    func remove(serial: String) {
        unlink((directory as NSString).appendingPathComponent(Self.fileName(serial: serial)))
    }
}
