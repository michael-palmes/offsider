import Foundation

/// HID modifier usages (page 7, 224 to 231) as Android `KeyEvent.META_*` bits: the side's bit plus the shared one.
enum AndroidKeyMeta {
    static let shiftOn: UInt32 = 0x1
    static let altOn: UInt32 = 0x2
    static let altLeftOn: UInt32 = 0x10
    static let altRightOn: UInt32 = 0x20
    static let shiftLeftOn: UInt32 = 0x40
    static let shiftRightOn: UInt32 = 0x80
    static let ctrlOn: UInt32 = 0x1000
    static let ctrlLeftOn: UInt32 = 0x2000
    static let ctrlRightOn: UInt32 = 0x4000
    static let metaOn: UInt32 = 0x10000
    static let metaLeftOn: UInt32 = 0x20000
    static let metaRightOn: UInt32 = 0x40000

    /// nil for a usage that is not a modifier.
    static func bits(for usage: UInt32) -> UInt32? {
        switch usage {
        case 224: return ctrlOn | ctrlLeftOn
        case 225: return shiftOn | shiftLeftOn
        case 226: return altOn | altLeftOn
        case 227: return metaOn | metaLeftOn
        case 228: return ctrlOn | ctrlRightOn
        case 229: return shiftOn | shiftRightOn
        case 230: return altOn | altRightOn
        case 231: return metaOn | metaRightOn
        default: return nil
        }
    }

    /// The meta state for the modifiers held: shared bits stay while either side is down.
    static func state(holding usages: Set<UInt32>) -> UInt32 {
        usages.reduce(0) { $0 | (bits(for: $1) ?? 0) }
    }
}
