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

    @Test("modifier downs, a press and the ups become one keycombination")
    func keyCombination() throws {
        let steps: [AndroidInputStep] = [.key(.down, usage: 224), .key(.press, usage: 6), .key(.up, usage: 224)]
        #expect(try AdbInputScript.scripts(for: steps) == ["input keycombination 113 31"])

        let two: [AndroidInputStep] = [.key(.down, usage: 224), .key(.down, usage: 225), .key(.press, usage: 4), .key(.up, usage: 225), .key(.up, usage: 224)]
        #expect(try AdbInputScript.scripts(for: two) == ["input keycombination 113 59 29"])
    }

    @Test("a held key or button is a long press; a press is a keyevent")
    func heldKeys() throws {
        #expect(try AdbInputScript.scripts(for: [.key(.down, usage: 40), .pause(2), .key(.up, usage: 40)]) == ["input keyevent --longpress 66"])
        #expect(try AdbInputScript.scripts(for: [.button(.down, .lock), .pause(1), .button(.up, .lock)]) == ["input keyevent --longpress 26"])
        #expect(try AdbInputScript.scripts(for: [.key(.press, usage: 40), .button(.press, .home)]) == ["input keyevent 66 && input keyevent 3"])
    }

    @Test("back, app-switch and the volume keys are their KEYCODE values")
    func androidButtons() throws {
        let presses: [AndroidInputStep] = [.button(.press, .back), .button(.press, .appSwitch), .button(.press, .volumeUp), .button(.press, .volumeDown)]
        #expect(try AdbInputScript.scripts(for: presses) == ["input keyevent 4 && input keyevent 187 && input keyevent 24 && input keyevent 25"])
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
}
