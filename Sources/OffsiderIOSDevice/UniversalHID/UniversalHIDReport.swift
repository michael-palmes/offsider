import Darwin
import Foundation

/// Raw HID reports for a device's UniversalHID surfaces, laid out as Xcode's own mirror sends them.
public enum UniversalHIDReport {
    public enum TouchState: UInt8, Sendable {
        case contact = 0xC2
        case release = 0x02
    }

    public static let touchscreenReportID: UInt8 = 0x09
    public static let touchscreenLength = 58
    public static let keyboardReportID: UInt8 = 0x01
    public static let keyboardLength = 39
    /// The keyboard bitmap's 240 bits cover usages 0 to 239, which holds every key and modifier (0xE0 to 0xE7).
    public static let keyboardUsageLimit = 240

    /// `mach_absolute_time()` in raw ticks, as the host's mirror stamps its reports, kept to the 48 bits the reports carry.
    public static func timestamp() -> UInt64 {
        mach_absolute_time() & 0xFFFF_FFFF_FFFF
    }

    /// One contact on the main touchscreen at 0...65535 on each panel axis; a tap is a contact then a release at the same point.
    public static func touchscreen(x: UInt16, y: UInt16, state: TouchState, timestamp: UInt64) -> Data {
        var bytes = [UInt8](repeating: 0, count: touchscreenLength)
        bytes[0] = touchscreenReportID
        bytes[1] = 0x01
        bytes[2] = 0x05
        bytes[3] = state.rawValue
        put(UInt64(x), 2, into: &bytes, at: 4)
        put(UInt64(y), 2, into: &bytes, at: 6)
        bytes[40] = 0x02
        put(timestamp, 6, into: &bytes, at: 44)
        return Data(bytes)
    }

    /// The whole set of keyboard-page usages held down; an empty set releases every key.
    public static func keyboard(pressedUsages: some Sequence<UInt8>, timestamp: UInt64 = 0) -> Data {
        var bytes = [UInt8](repeating: 0, count: keyboardLength)
        bytes[0] = keyboardReportID
        for usage in pressedUsages where Int(usage) < keyboardUsageLimit {
            bytes[1 + Int(usage) / 8] |= 1 << (usage % 8)
        }
        put(timestamp, 6, into: &bytes, at: 31)
        return Data(bytes)
    }

    /// A fraction of a panel axis as the touchscreen's 16-bit coordinate, clamped to the panel.
    public static func axis(_ fraction: Double) -> UInt16 {
        guard fraction.isFinite, fraction > 0 else { return 0 }
        return UInt16((min(fraction, 1) * 65535).rounded())
    }

    private static func put(_ value: UInt64, _ width: Int, into bytes: inout [UInt8], at offset: Int) {
        for index in 0..<width {
            bytes[offset + index] = UInt8(truncatingIfNeeded: value >> (8 * index))
        }
    }
}
