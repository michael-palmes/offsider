import Foundation

/// HID keyboard usages (page 7) to Android `KEYCODE_*` values; usages outside the table are refused, never guessed.
enum AndroidKeyTable {
    static func keyCode(for usage: UInt32) -> Int? {
        switch usage {
        case 4...29: return Int(usage) + 25
        case 30...38: return Int(usage) - 22
        case 39: return 7
        case 58...69: return Int(usage) + 73
        default: return fixed[usage]
        }
    }

    /// The gRPC `KeyboardEvent` code: a bare usage is dropped with an OK status, so the page goes in the top half.
    static func usbCode(for usage: UInt32) -> UInt32? {
        keyCode(for: usage) == nil ? nil : 0x07 << 16 | usage
    }

    static func requireKeyCode(for usage: UInt32) throws -> Int {
        guard let code = keyCode(for: usage) else { throw AndroidError.unsupportedKey(usage) }
        return code
    }

    private static let fixed: [UInt32: Int] = [
        40: 66, 41: 111, 42: 67, 43: 61, 44: 62,
        45: 69, 46: 70, 47: 71, 48: 72, 49: 73,
        51: 74, 52: 75, 53: 68, 54: 55, 55: 56, 56: 76,
        57: 115,
        73: 124, 74: 122, 75: 92, 76: 112, 77: 123, 78: 93,
        79: 22, 80: 21, 81: 20, 82: 19,
        127: 164, 128: 24, 129: 25,
        224: 113, 225: 59, 226: 57, 227: 117, 228: 114, 229: 60, 230: 58, 231: 118,
    ]
}
