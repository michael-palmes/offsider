import Darwin
import Foundation
import OffsiderCore

/// `<private>/ios-devices/<udid>/`, each level created 0700 and checked.
enum IOSDevicePaths {
    static let directoryName = "ios-devices"

    static func device(_ udid: String, root: String) throws -> String {
        let devices = try OffsiderPrivateDirectory.ensureSubdirectory(directoryName, root: root)
        let path = (devices as NSString).appendingPathComponent(safeName(udid))
        try OffsiderPrivateDirectory.ensurePrivateDirectory(path, uid: getuid())
        return path
    }

    static func subdirectory(_ name: String, of udid: String, root: String) throws -> String {
        let path = (try device(udid, root: root) as NSString).appendingPathComponent(name)
        try OffsiderPrivateDirectory.ensurePrivateDirectory(path, uid: getuid())
        return path
    }

    /// The device directories that exist, without creating any.
    static func knownDevices(root: String) -> [String] {
        let devices = (root as NSString).appendingPathComponent(directoryName)
        return ((try? FileManager.default.contentsOfDirectory(atPath: devices)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
    }

    /// UDIDs are hex and dashes already; anything else is dropped so a name can never leave the directory.
    static func safeName(_ udid: String) -> String {
        String(udid.filter { $0.isHexDigit || $0 == "-" })
    }
}
