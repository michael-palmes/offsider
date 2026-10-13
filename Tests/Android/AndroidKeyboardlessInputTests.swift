import Foundation
import OffsiderCore
import Testing
@testable import OffsiderAndroid

@Suite("Android input on an AVD without a hardware keyboard")
@MainActor
struct AndroidKeyboardlessInputTests {
    static let device = AndroidGrpcInputTests.device
    static let noKeyboard = "hw.keyboard = false\nhw.keyboard.charmap = qwerty2\n"

    static func session(_ rig: AndroidGrpcInputTests.Rig) async throws -> any TextInputSession {
        try #require(try await rig.backend.openInputSession(for: Self.device) as? any TextInputSession)
    }

    @Test("ASCII text and its Return go over adb, since the guest drops every gRPC key", arguments: [noKeyboard, "hw.keyboard=no\n"])
    func textOverAdb(hardware: String) async throws {
        let rig = try AndroidGrpcInputTests.rig(avdHardware: hardware)
        try await Self.session(rig).typeText("abc\n")

        #expect(rig.adbScripts == ["input text 'abc' && input keyevent 66"])
        #expect(rig.emulator.calls.isEmpty)
    }

    @Test("with a hardware keyboard, or no hw.keyboard to read, text stays on gRPC", arguments: ["hw.keyboard = true\n", "hw.keyboard=yes\n", "hw.lcd.density = 440\n"])
    func keyboardKeepsGrpc(hardware: String) async throws {
        let rig = try AndroidGrpcInputTests.rig(avdHardware: hardware)
        try await Self.session(rig).typeText("abc")

        #expect(rig.emulator.calls == [.key(.text("abc"))])
        #expect(rig.adbScripts.isEmpty)
    }

    @Test("non-ASCII text is still pasted through the gRPC clipboard")
    func pasteUnchanged() async throws {
        let rig = try AndroidGrpcInputTests.rig(emulator: FakeEmulator(clipboard: "sentinel"), avdHardware: Self.noKeyboard)
        try await Self.session(rig).typeText("é")

        #expect(rig.emulator.calls == [.getClipboard, .setClipboard("é"), .setClipboard("sentinel")])
        #expect(rig.adbScripts.filter { $0.hasPrefix("input") } == ["input keyevent 279"])
    }

    @Test("keys and buttons go over adb, while touches stay on gRPC")
    func keysSplitFromTouches() async throws {
        let rig = try AndroidGrpcInputTests.rig(avdHardware: Self.noKeyboard)
        try await rig.backend.perform(.composite([.shortKeyPress(42), .tapAt(x: 525, y: 1050), .shortButtonPress(.back), .shortButtonPress(.menu)]), on: Self.device)

        #expect(rig.emulator.calls == [rig.touch(525, 1050, 1), rig.touch(525, 1050, 0)])
        #expect(rig.adbScripts == ["input keyevent 67", "input keyevent 4 && input keyevent 82"])
    }

    @Test("a modifier with its key is one keycombination, and a held key a long press")
    func heldKeys() async throws {
        let rig = try AndroidGrpcInputTests.rig(avdHardware: Self.noKeyboard)
        try await rig.backend.perform(.composite([
            .keyboard(direction: .down, keyCode: 224), .shortKeyPress(4), .keyboard(direction: .up, keyCode: 224),
            .keyboard(direction: .down, keyCode: 225), .delay(0.5), .keyboard(direction: .up, keyCode: 225),
        ]), on: Self.device)

        #expect(rig.adbScripts == ["getprop ro.build.version.sdk", "input keycombination 113 29 && input keyevent --longpress 59"])
        #expect(rig.emulator.calls.isEmpty)
    }

    @Test("a key held across a touch is refused before anything is sent")
    func keyAcrossTouchRefused() async throws {
        let rig = try AndroidGrpcInputTests.rig(avdHardware: Self.noKeyboard)
        let error = await #expect(throws: AndroidError.self) {
            try await rig.backend.perform(.composite([.keyboard(direction: .down, keyCode: 225), .tapAt(x: 10, y: 10), .keyboard(direction: .up, keyCode: 225)]), on: Self.device)
        }

        #expect(error?.kind == .notSupported)
        #expect(rig.emulator.calls.isEmpty)
        #expect(rig.adbScripts.isEmpty)
    }
}
