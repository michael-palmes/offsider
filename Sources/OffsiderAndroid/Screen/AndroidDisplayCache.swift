import CryptoKit
import Foundation
import OffsiderCore

/// A phone's active panel, size and device state from its last capture, trusted only while connection, state and size still match.
struct AndroidDisplayCacheEntry: Equatable, Sendable {
    static let version = 2
    static let maximumBytes = 16_384

    var serial: String
    /// adb's `transport_id` for the connection the entry was learnt on.
    var transportId: String
    /// The physical display id `screencap -d` takes; digits only.
    var displayId: String
    /// `inner`, `cover` or `main`.
    var role: String
    /// Whether `screencap` without `-d` captured the active panel, as the Fold's does, so a later capture can follow a fold without `-d`.
    var followsActive: Bool
    /// Every state `print-states` listed; empty before API 31.
    var states: [AndroidDeviceState.State]
    /// The committed state when the entry was learnt; nil before API 31, where only a plain capture is trusted, on its size.
    var committed: AndroidDeviceState.State?
    var width: Int
    var height: Int

    /// Only digits ever reach the shell, so a tampered file cannot add to the command.
    static func isDisplayId(_ text: String) -> Bool {
        !text.isEmpty && text.count <= 32 && text.unicodeScalars.allSatisfy { ("0"..."9").contains($0) }
    }

    /// `<first 16 hex of SHA-256 of "android:serial">.json`, so a serial never reaches a file name.
    static func fileName(serial: String) -> String {
        let digest = SHA256.hash(data: Data("android:\(serial)".utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined() + ".json"
    }

    func encoded() -> Data {
        func state(_ state: AndroidDeviceState.State) -> [String: Any] {
            ["identifier": state.identifier, "name": state.name]
        }
        let object: [String: Any] = [
            "version": Self.version,
            "serial": serial,
            "transportId": transportId,
            "displayId": displayId,
            "role": role,
            "followsActive": followsActive,
            "states": states.map(state),
            "committed": committed.map(state) ?? NSNull(),
            "width": width,
            "height": height,
        ]
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
    }

    /// Nil for anything malformed, another version, or a display id that is not digits.
    init?(data: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (object["version"] as? NSNumber)?.intValue == Self.version,
              let serial = object["serial"] as? String, let transportId = object["transportId"] as? String,
              let displayId = object["displayId"] as? String, Self.isDisplayId(displayId),
              let role = object["role"] as? String, let followsActive = (object["followsActive"] as? NSNumber)?.boolValue,
              let width = (object["width"] as? NSNumber)?.intValue, let height = (object["height"] as? NSNumber)?.intValue,
              width > 0, height > 0 else {
            return nil
        }
        func state(_ value: Any?) -> AndroidDeviceState.State? {
            guard let value = value as? [String: Any], let identifier = (value["identifier"] as? NSNumber)?.intValue,
                  let name = value["name"] as? String else { return nil }
            return AndroidDeviceState.State(identifier: identifier, name: name)
        }
        self.init(
            serial: serial, transportId: transportId, displayId: displayId, role: role,
            states: (object["states"] as? [Any] ?? []).compactMap(state), committed: state(object["committed"]),
            followsActive: followsActive, width: width, height: height
        )
    }

    init(
        serial: String, transportId: String, displayId: String, role: String, states: [AndroidDeviceState.State],
        committed: AndroidDeviceState.State?, followsActive: Bool, width: Int, height: Int
    ) {
        self.serial = serial
        self.transportId = transportId
        self.displayId = displayId
        self.role = role
        self.states = states
        self.committed = committed
        self.followsActive = followsActive
        self.width = width
        self.height = height
    }
}

/// One 0600 file per phone under the private directory's `displays/`; reading never follows a symlink and never throws.
struct AndroidDisplayCache: Sendable {
    static let environmentKey = "OFFSIDER_DISPLAY_CACHE"
    static let directoryName = "displays"

    let directory: String

    /// On unless `OFFSIDER_DISPLAY_CACHE=off`.
    static func isEnabled(_ environment: [String: String]) -> Bool {
        environment[environmentKey]?.trimmingCharacters(in: .whitespaces).lowercased() != "off"
    }

    /// The entry for `serial`, or nil; an unreadable or foreign entry is removed.
    func load(serial: String) -> AndroidDisplayCacheEntry? {
        let name = AndroidDisplayCacheEntry.fileName(serial: serial)
        guard let data = try? OffsiderPrivateDirectory.readOwnedFile(named: name, in: directory, maxBytes: AndroidDisplayCacheEntry.maximumBytes) else {
            return nil
        }
        guard let entry = AndroidDisplayCacheEntry(data: data), entry.serial == serial else {
            OffsiderPrivateDirectory.removeFile(named: name, in: directory)
            return nil
        }
        return entry
    }

    func save(_ entry: AndroidDisplayCacheEntry) {
        try? OffsiderPrivateDirectory.writeAtomically(entry.encoded(), named: AndroidDisplayCacheEntry.fileName(serial: entry.serial), in: directory)
    }

    func remove(serial: String) {
        OffsiderPrivateDirectory.removeFile(named: AndroidDisplayCacheEntry.fileName(serial: serial), in: directory)
    }
}
