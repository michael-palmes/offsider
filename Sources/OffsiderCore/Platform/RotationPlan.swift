import Foundation

/// Android's `accelerometer_rotation` (auto-rotate) and `user_rotation`, read in one round trip; nil when unreadable.
public struct AutoRotateState: Equatable, Sendable {
    public let accelerometerRotation: Int?
    public let userRotation: Int?
    /// The kernel's boot id, read in the same round trip so a phone's record can name its boot; nil when unreadable.
    public let bootID: String?

    public init(accelerometerRotation: Int?, userRotation: Int?, bootID: String? = nil) {
        self.accelerometerRotation = accelerometerRotation
        self.userRotation = userRotation
        self.bootID = bootID
    }

    public static let readScript = "settings get system accelerometer_rotation; settings get system user_rotation; cat /proc/sys/kernel/random/boot_id 2>/dev/null || true"

    /// Two lines, each a number or `null` (never set, which Android reads as 0), then the boot id when the device let it be read.
    public static func parse(_ output: String) -> AutoRotateState? {
        let lines = output.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        guard lines.count >= 2 else { return nil }
        func value(_ text: String) -> Int? { text == "null" ? 0 : Int(text) }
        guard let accelerometer = value(lines[0]), let user = value(lines[1]) else { return nil }
        let bootID = lines.count > 2 ? UUID(uuidString: lines[2]).map { $0.uuidString.lowercased() } : nil
        return AutoRotateState(accelerometerRotation: accelerometer, userRotation: user, bootID: bootID)
    }

    public var autoRotate: Bool? { accelerometerRotation.map { $0 != 0 } }
}

/// What auto-rotate was before Offsider first turned the device in this boot, so `orientation portrait` can put it back.
public struct RotationRecord: Equatable, Sendable {
    public let accelerometerRotation: Int
    public let userRotation: Int
    /// The device boot it was taken in; a record from an earlier boot is ignored.
    public let bootMarker: String?

    public init(accelerometerRotation: Int, userRotation: Int, bootMarker: String?) {
        self.accelerometerRotation = accelerometerRotation
        self.userRotation = userRotation
        self.bootMarker = bootMarker
    }

    public var fileContents: String {
        "accelerometer_rotation=\(accelerometerRotation)\nuser_rotation=\(userRotation)\nbootMarker=\(bootMarker ?? "")\n"
    }

    public static func parse(_ text: String) -> RotationRecord? {
        var fields: [Substring: Substring] = [:]
        for line in text.split(separator: "\n") {
            guard let separator = line.firstIndex(of: "=") else { continue }
            fields[line[..<separator]] = line[line.index(after: separator)...]
        }
        guard let accelerometer = fields["accelerometer_rotation"].flatMap({ Int($0) }),
              let user = fields["user_rotation"].flatMap({ Int($0) }) else { return nil }
        let marker = fields["bootMarker"].map(String.init).flatMap { $0.isEmpty ? nil : $0 }
        return RotationRecord(accelerometerRotation: accelerometer, userRotation: user, bootMarker: marker)
    }
}

/// The record bookkeeping around one `orientation` request on Android.
public struct RotationPlan: Equatable, Sendable {
    /// Saved before the turn; nil keeps whatever is stored.
    public let recordToWrite: RotationRecord?
    /// Removed after the turn: restored, or from another boot.
    public let deleteRecord: Bool
    /// `accelerometer_rotation` to write back once the device is portrait.
    public let restoreAccelerometer: Int?

    public init(recordToWrite: RotationRecord?, deleteRecord: Bool, restoreAccelerometer: Int?) {
        self.recordToWrite = recordToWrite
        self.deleteRecord = deleteRecord
        self.restoreAccelerometer = restoreAccelerometer
    }

    /// Any turn first records `before` unless this boot has a record, and portrait restores and forgets it; nil when a turn needs a record `before` cannot give.
    public static func make(before: AutoRotateState?, target: DeviceOrientation, record: RotationRecord?, bootMarker: String?, turning: Bool) -> RotationPlan? {
        var current = record.flatMap { $0.bootMarker == bootMarker ? $0 : nil }
        var recordToWrite: RotationRecord?
        if current == nil, turning {
            guard let accelerometer = before?.accelerometerRotation, let user = before?.userRotation else { return nil }
            recordToWrite = RotationRecord(accelerometerRotation: accelerometer, userRotation: user, bootMarker: bootMarker)
            current = recordToWrite
        }
        guard target == .portrait, let current else {
            return RotationPlan(recordToWrite: recordToWrite, deleteRecord: false, restoreAccelerometer: nil)
        }
        return RotationPlan(recordToWrite: recordToWrite, deleteRecord: true, restoreAccelerometer: current.accelerometerRotation)
    }
}

/// Reads and writes auto-rotate; Android only.
public protocol AutoRotateControlling: DeviceBackend {
    func autoRotateState(on id: DeviceID) async throws -> AutoRotateState?
    func setAccelerometerRotation(_ value: Int, on id: DeviceID) async throws
}

/// `autoRotate {before, now, restored}` and `userRotation {before, now}` for `orientation --json` on Android.
public struct RotationReport: Equatable, Sendable {
    public let before: AutoRotateState?
    public let now: AutoRotateState?
    public let restored: Bool

    public init(before: AutoRotateState?, now: AutoRotateState?, restored: Bool) {
        self.before = before
        self.now = now
        self.restored = restored
    }
}
