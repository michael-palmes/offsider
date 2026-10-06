import Foundation

/// Android's `accelerometer_rotation` (auto-rotate) and `user_rotation`, read in one round trip; nil when unreadable.
public struct AutoRotateState: Equatable, Sendable {
    public let accelerometerRotation: Int?
    public let userRotation: Int?

    public init(accelerometerRotation: Int?, userRotation: Int?) {
        self.accelerometerRotation = accelerometerRotation
        self.userRotation = userRotation
    }

    public static let readScript = "settings get system accelerometer_rotation; settings get system user_rotation"

    /// Two lines, each a number or `null` (never set, which Android reads as 0).
    public static func parse(_ output: String) -> AutoRotateState? {
        let lines = output.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        guard lines.count >= 2 else { return nil }
        func value(_ text: String) -> Int? { text == "null" ? 0 : Int(text) }
        guard let accelerometer = value(lines[0]), let user = value(lines[1]) else { return nil }
        return AutoRotateState(accelerometerRotation: accelerometer, userRotation: user)
    }

    public var autoRotate: Bool? { accelerometerRotation.map { $0 != 0 } }
}

/// What auto-rotate was before Offsider first turned the device away from portrait, so `orientation portrait` can put it back.
public struct RotationRecord: Equatable, Sendable {
    public let accelerometerRotation: Int
    public let userRotation: Int
    /// The emulator boot it was taken in; a record from an earlier boot is ignored.
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

    /// A non-portrait target keeps the first record of this boot; portrait restores and forgets it.
    public static func make(before: AutoRotateState?, target: DeviceOrientation, record: RotationRecord?, bootMarker: String?) -> RotationPlan {
        let current = record.flatMap { $0.bootMarker == bootMarker ? $0 : nil }
        let stale = record != nil && current == nil
        if target == .portrait {
            return RotationPlan(recordToWrite: nil, deleteRecord: record != nil, restoreAccelerometer: current?.accelerometerRotation)
        }
        guard current == nil, let accelerometer = before?.accelerometerRotation, let user = before?.userRotation else {
            return RotationPlan(recordToWrite: nil, deleteRecord: stale && before == nil, restoreAccelerometer: nil)
        }
        return RotationPlan(
            recordToWrite: RotationRecord(accelerometerRotation: accelerometer, userRotation: user, bootMarker: bootMarker),
            deleteRecord: false,
            restoreAccelerometer: nil
        )
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
