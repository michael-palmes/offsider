import Foundation
import OffsiderCore
import Testing
@testable import OffsiderAndroid

@Suite("Android key table")
struct AndroidKeyTableTests {
    static let supported: [UInt32] = Array(4...49) + Array(51...69) + Array(73...82) + [127, 128, 129] + Array(224...231)

    @Test("every supported usage has a KEYCODE and the USB page code the emulator needs")
    func everyUsageMaps() {
        for usage in Self.supported {
            #expect(AndroidKeyTable.keyCode(for: usage) != nil, "usage \(usage)")
            #expect(AndroidKeyTable.usbCode(for: usage) == 0x070000 + usage, "usage \(usage)")
        }
    }

    @Test("letters, digits, editing keys and modifiers match Android's KEYCODE values", arguments: [
        (UInt32(4), 29), (29, 54), (30, 8), (38, 16), (39, 7), (40, 66), (41, 111), (42, 67), (43, 61), (44, 62),
        (53, 68), (57, 115), (58, 131), (69, 142), (74, 122), (76, 112), (79, 22), (82, 19), (128, 24),
        (224, 113), (225, 59), (227, 117), (231, 118),
    ] as [(UInt32, Int)])
    func spotChecks(usage: UInt32, keyCode: Int) {
        #expect(AndroidKeyTable.keyCode(for: usage) == keyCode)
    }

    @Test("usages outside the table have no code and a message listing the supported ranges", arguments: [UInt32(0), 3, 50, 70, 104, 232])
    func unmapped(usage: UInt32) {
        #expect(AndroidKeyTable.keyCode(for: usage) == nil)
        #expect(AndroidKeyTable.usbCode(for: usage) == nil)
        let error = #expect(throws: AndroidError.self) { try AndroidKeyTable.requireKeyCode(for: usage) }
        #expect(error?.message == "Key \(usage) has no Android equivalent. Supported HID usages: 4 to 49, 51 to 57, 58 to 69 (F1 to F12), 73 to 82, 127 to 129 and 224 to 231.")
    }

    @Test("home and lock are Android's HOME and POWER keys; iOS-only buttons are refused by name")
    func buttons() {
        #expect(AndroidButtonMap.keyCode(for: .home) == 3)
        #expect(AndroidButtonMap.keyCode(for: .lock) == 26)
        let error = #expect(throws: AndroidError.self) { try AndroidButtonMap.requireKeyCode(for: .sideButton) }
        #expect(error?.message == "The side-button button is iOS only. Android buttons in this build: home, lock.")
    }
}
