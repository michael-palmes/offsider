import Foundation
import OffsiderCore
import Testing
@testable import OffsiderAndroid

@Suite("adb input scripts")
struct AdbInputScriptTests {
    @Test("a tap is input tap in whole logical pixels")
    func tap() throws {
        #expect(try AdbInputScript.scripts(for: [.tap(AndroidPoint(x: 525.4, y: 1049.6))]) == ["input tap 525 1050"])
    }

    @Test("a swipe carries its duration in milliseconds")
    func swipe() throws {
        let steps = [AndroidInputStep.swipe(from: AndroidPoint(x: 540, y: 1800), to: AndroidPoint(x: 540, y: 600), duration: 1, steps: 8)]
        #expect(try AdbInputScript.scripts(for: steps) == ["input swipe 540 1800 540 600 1000"])
    }

    @Test("a drag is one script of motion events with fractional sleeps")
    func drag() throws {
        let steps: [AndroidInputStep] = [
            .touch(.down, AndroidPoint(x: 0, y: 0)), .pause(0.05),
            .touch(.move, AndroidPoint(x: 50, y: 0)), .pause(0.1),
            .touch(.up, AndroidPoint(x: 50, y: 0)),
        ]
        #expect(try AdbInputScript.scripts(for: steps) == [
            "input motionevent DOWN 0 0 && sleep 0.05 && input motionevent MOVE 50 0 && sleep 0.1 && input motionevent UP 50 0",
        ])
        #expect(abs(AdbInputScript.waitTime(of: steps) - 0.15) < 1e-9)
    }

    @Test("the same drag is a motionevent script from API 29, and with an unread level")
    func dragFromAPI29() throws {
        let steps: [AndroidInputStep] = [.touch(.down, AndroidPoint(x: 0, y: 0)), .touch(.move, AndroidPoint(x: 50, y: 0)), .touch(.up, AndroidPoint(x: 50, y: 0))]
        for level in [29, 36, nil] {
            #expect(try AdbInputScript.scripts(for: steps, apiLevel: level) == [
                "input motionevent DOWN 0 0 && input motionevent MOVE 50 0 && input motionevent UP 50 0",
            ])
        }
    }

    @Test("`input` sends motion events from Android 10 (API 29) on, and an unread level counts as recent")
    func motionEventLevels() {
        #expect([28, 29, 36, nil].map { AdbInputScript.sendsMotionEvents(apiLevel: $0) } == [false, true, true, true])
    }

    @Test("only touch phases other than a held tap need `input motionevent`")
    func detectsMotionEvent() {
        let p = AndroidPoint(x: 10, y: 20)
        let q = AndroidPoint(x: 30, y: 20)
        #expect(!AdbInputScript.needsMotionEvent([.touch(.down, p), .pause(0.1), .touch(.up, p)]))
        #expect(!AdbInputScript.needsMotionEvent([.pause(0.2), .touch(.down, p), .touch(.up, p), .tap(q), .touch(.down, q), .pause(1), .pause(1), .touch(.up, q)]))
        #expect(!AdbInputScript.needsMotionEvent([.tap(p), .swipe(from: p, to: q, duration: 1, steps: 4), .key(.press, usage: 40)]))
        #expect(AdbInputScript.needsMotionEvent([.touch(.down, p), .pause(0.1), .touch(.move, q), .touch(.up, q)]))
        #expect(AdbInputScript.needsMotionEvent([.touch(.down, p), .pause(0.1), .touch(.up, q)]))
        #expect(AdbInputScript.needsMotionEvent([.touch(.down, p)]))
        #expect(AdbInputScript.needsMotionEvent([.pause(0.25), .touch(.up, p)]))
        #expect(AdbInputScript.needsMotionEvent([.touch(.down, p), .tap(q), .touch(.up, p)]))
    }

    @Test("before API 29 a held tap is a swipe that stays put for its hold, and an unheld one input tap")
    func heldTapBeforeAPI29() throws {
        let p = AndroidPoint(x: 550.4, y: 1374.6)
        #expect(try AdbInputScript.scripts(for: [.touch(.down, p), .pause(0.5), .pause(0.3), .touch(.up, p)], apiLevel: 28) == ["input swipe 550 1375 550 1375 800"])
        #expect(try AdbInputScript.scripts(for: [.pause(0.2), .touch(.down, p), .touch(.up, p), .key(.press, usage: 40)], apiLevel: 28) == [
            "sleep 0.2 && input tap 550 1375 && input keyevent 66",
        ])
    }

    @Test("before API 29 a drag or a lone touch phase is refused, never sent as a motionevent `input` would ignore")
    func dragRefusedBeforeAPI29() {
        let p = AndroidPoint(x: 10, y: 20)
        for steps: [AndroidInputStep] in [[.touch(.down, p), .touch(.move, AndroidPoint(x: 10, y: 90)), .touch(.up, p)], [.touch(.down, p)], [.touch(.up, p)]] {
            let error = #expect(throws: AndroidError.self) { try AdbInputScript.scripts(for: steps, apiLevel: 28) }
            #expect(error?.kind == .notSupported)
        }
    }

    @Test("before API 31 a key combination is refused, never sent as a keycombination `input` would ignore")
    func keyCombinationRefusedBeforeAPI31() throws {
        let steps: [AndroidInputStep] = [.key(.down, usage: 224), .key(.press, usage: 4), .key(.up, usage: 224)]
        let error = #expect(throws: AndroidError.self) { try AdbInputScript.scripts(for: steps, apiLevel: 30) }
        #expect(error?.kind == .notSupported)
        #expect(try AdbInputScript.scripts(for: steps, apiLevel: 31) == ["input keycombination 113 29"])
    }

    @Test("modifier downs, a press and the ups become one keycombination")
    func keyCombination() throws {
        let steps: [AndroidInputStep] = [.key(.down, usage: 224), .key(.press, usage: 6), .key(.up, usage: 224)]
        #expect(try AdbInputScript.scripts(for: steps) == ["input keycombination 113 31"])

        let two: [AndroidInputStep] = [.key(.down, usage: 224), .key(.down, usage: 225), .key(.press, usage: 4), .key(.up, usage: 225), .key(.up, usage: 224)]
        #expect(try AdbInputScript.scripts(for: two) == ["input keycombination 113 59 29"])
    }

    @Test("`input` sends key combinations from Android 12 (API 31) on, and an unread level counts as recent")
    func keyCombinationLevels() {
        #expect(!AdbInputScript.sendsKeyCombinations(apiLevel: 28))
        #expect(!AdbInputScript.sendsKeyCombinations(apiLevel: 30))
        #expect(AdbInputScript.sendsKeyCombinations(apiLevel: 31))
        #expect(AdbInputScript.sendsKeyCombinations(apiLevel: 36))
        #expect(AdbInputScript.sendsKeyCombinations(apiLevel: nil))
    }

    @Test("only steps that become an `input keycombination` count as a key combination")
    func detectsKeyCombination() {
        let ctrl: UInt32 = 224
        #expect(AdbInputScript.hasKeyCombination([.key(.down, usage: ctrl), .key(.press, usage: 4), .key(.up, usage: ctrl), .pause(0.05), .key(.press, usage: 42)]))
        #expect(AdbInputScript.hasKeyCombination([.tap(AndroidPoint(x: 1, y: 1)), .key(.down, usage: ctrl), .key(.press, usage: 6), .key(.up, usage: ctrl)]))
        #expect(!AdbInputScript.hasKeyCombination([.key(.press, usage: 40), .button(.press, .home)]))
        #expect(!AdbInputScript.hasKeyCombination([.key(.down, usage: 40), .pause(2), .key(.up, usage: 40)]))
        #expect(!AdbInputScript.hasKeyCombination([.key(.down, usage: ctrl), .key(.press, usage: 4)]))
    }

    @Test("a held key or button is a long press; a press is a keyevent")
    func heldKeys() throws {
        #expect(try AdbInputScript.scripts(for: [.key(.down, usage: 40), .pause(2), .key(.up, usage: 40)]) == ["input keyevent --longpress 66"])
        #expect(try AdbInputScript.scripts(for: [.button(.down, .lock), .pause(1), .button(.up, .lock)]) == ["input keyevent --longpress 26"])
        #expect(try AdbInputScript.scripts(for: [.key(.press, usage: 40), .button(.press, .home)]) == ["input keyevent 66 && input keyevent 3"])
    }

    @Test("back, app-switch, the volume keys and menu are their KEYCODE values")
    func androidButtons() throws {
        let presses: [AndroidInputStep] = [.button(.press, .back), .button(.press, .appSwitch), .button(.press, .volumeUp), .button(.press, .volumeDown), .button(.press, .menu)]
        #expect(try AdbInputScript.scripts(for: presses) == ["input keyevent 4 && input keyevent 187 && input keyevent 24 && input keyevent 25 && input keyevent 82"])
    }

    @Test("HID usage 118 (Menu) is KEYCODE_MENU over adb")
    func menuUsage() throws {
        #expect(try AdbInputScript.scripts(for: [.key(.press, usage: 118)]) == ["input keyevent 82"])
    }

    @Test("a key held across other input cannot be sent over adb")
    func unmatchedDown() {
        #expect(throws: AndroidError.self) {
            try AdbInputScript.scripts(for: [.key(.down, usage: 4), .tap(AndroidPoint(x: 1, y: 1))])
        }
    }

    @Test("long step lists split into several scripts, none longer than the limit")
    func splitting() throws {
        let steps = Array(repeating: AndroidInputStep.tap(AndroidPoint(x: 1000, y: 2000)), count: 2000)
        let scripts = try AdbInputScript.scripts(for: steps)
        #expect(scripts.count > 1)
        #expect(scripts.allSatisfy { $0.count <= AdbInputScript.maxScriptLength })
        #expect(scripts.joined(separator: " && ").components(separatedBy: "input tap").count - 1 == 2000)
    }

    @Test("two fingers are refused over `input`, which moves one finger, naming the routes that can")
    func twoFingersRefused() {
        let error = #expect(throws: AndroidError.self) {
            try AdbInputScript.scripts(for: [.touches(.down, [AndroidPoint(x: 1, y: 1), AndroidPoint(x: 2, y: 1)])])
        }
        #expect(error?.kind == .notSupported)
        #expect(error?.message.contains("OFFSIDER_ANDROID_INPUT=helper") == true)
    }
}
