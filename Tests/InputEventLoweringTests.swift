import FBSimulatorControl
import Foundation
import OffsiderCore
import Testing
@testable import Offsider

@Suite("Input Event Lowering Tests")
struct InputEventLoweringTests {
    @Test("hardware buttons lower to the named idb buttons")
    func hardwareButtonsLowerToNamedIDBButtons() {
        #expect(HardwareButton.applePay.hidButton == .applePay)
        #expect(HardwareButton.home.hidButton == .homeButton)
        #expect(HardwareButton.lock.hidButton == .lock)
        #expect(HardwareButton.sideButton.hidButton == .sideButton)
        #expect(HardwareButton.siri.hidButton == .siri)
        #expect(Set(HardwareButton.allCases.compactMap(\.hidButton)) == Set(FBSimulatorHIDButton.allCases))
    }

    @Test("Android-only buttons throw on iOS instead of reaching the HID layer", arguments: [HardwareButton.back, .appSwitch, .volumeUp, .volumeDown])
    func androidButtonsThrowOnIOS(button: HardwareButton) {
        #expect(button.hidButton == nil)
        #expect(throws: CLIError.self) { try InputEvent.shortButtonPress(button).hidEvent() }
        #expect(throws: CLIError.self) { try InputEvent.composite([.delay(0.1), .button(direction: .down, button: button)]).hidEvent() }
    }

    @Test("every button command maps to a distinct hardware button")
    func everyButtonCommandMapsToDistinctHardwareButton() {
        let mapped = ButtonType.allCases.map(\.hardwareButton)

        #expect(Set(mapped) == Set(HardwareButton.allCases))
        #expect(mapped.count == HardwareButton.allCases.count)
        #expect(ButtonType.home.hardwareButton.hidButton == .homeButton)
        #expect(ButtonType.sideButton.hardwareButton.hidButton == .sideButton)
    }

    @Test("typed text lowers to plain and shifted key presses")
    func typedTextLowersToPlainAndShiftedKeyPresses() throws {
        let events = try TextToHIDEvents.convertTextToHIDEvents("aA")

        #expect(try InputEvent.composite(events).hidEvent() == .composite([
            .keyboard(direction: .down, keyCode: 4),
            .keyboard(direction: .up, keyCode: 4),
            .keyboard(direction: .down, keyCode: 225),
            .keyboard(direction: .down, keyCode: 4),
            .keyboard(direction: .up, keyCode: 4),
            .keyboard(direction: .up, keyCode: 225)
        ]))
    }

    @Test("directions lower to idb directions")
    func directionsLowerToIDBDirections() {
        #expect(InputDirection.down.hidDirection == .down)
        #expect(InputDirection.up.hidDirection == .up)
    }

    @Test("single events lower to the idb events commands dispatch")
    func singleEventsLowerToIDBEvents() throws {
        #expect(try InputEvent.tapAt(x: 10, y: 20).hidEvent() == .composite([
            .touch(direction: .down, x: 10, y: 20),
            .touch(direction: .up, x: 10, y: 20)
        ]))
        #expect(try InputEvent.touch(direction: .down, x: 1.5, y: 2.5).hidEvent() == .touch(direction: .down, x: 1.5, y: 2.5))
        #expect(try InputEvent.touch(direction: .up, x: 3, y: 4).hidEvent() == .touch(direction: .up, x: 3, y: 4))
        #expect(try InputEvent.button(direction: .down, button: .lock).hidEvent() == .button(direction: .down, button: .lock))
        #expect(try InputEvent.shortButtonPress(.home).hidEvent() == .composite([
            .button(direction: .down, button: .homeButton),
            .button(direction: .up, button: .homeButton)
        ]))
        #expect(try InputEvent.keyboard(direction: .up, keyCode: 225).hidEvent() == .keyboard(direction: .up, keyCode: 225))
        #expect(try InputEvent.shortKeyPress(40).hidEvent() == .composite([
            .keyboard(direction: .down, keyCode: 40),
            .keyboard(direction: .up, keyCode: 40)
        ]))
        #expect(try InputEvent.delay(0.25).hidEvent() == .delay(0.25))
    }

    @Test("swipes lower to the idb swipe expansion")
    func swipesLowerToIDBSwipeExpansion() throws {
        let lowered = try InputEvent.swipe(100, yStart: 600, xEnd: 100, yEnd: 200, delta: 50, duration: 1).hidEvent()

        #expect(lowered == .swipe(100, yStart: 600, xEnd: 100, yEnd: 200, delta: 50, duration: 1))
        guard case let .composite(events) = lowered else {
            Issue.record("A swipe must lower to a composite of touches")
            return
        }
        #expect(events.first == .touch(direction: .down, x: 100, y: 600))
        #expect(events.last == .touch(direction: .up, x: 100, y: 200))
    }

    @Test("nested composites keep their order and nesting")
    func nestedCompositesKeepOrderAndNesting() throws {
        let event = InputEvent.composite([
            .delay(0.5),
            .composite([
                .button(direction: .down, button: .sideButton),
                .delay(2),
                .button(direction: .up, button: .sideButton)
            ]),
            .tapAt(x: 5, y: 6),
            .delay(1)
        ])

        #expect(try event.hidEvent() == .composite([
            .delay(0.5),
            .composite([
                .button(direction: .down, button: .sideButton),
                .delay(2),
                .button(direction: .up, button: .sideButton)
            ]),
            .composite([
                .touch(direction: .down, x: 5, y: 6),
                .touch(direction: .up, x: 5, y: 6)
            ]),
            .delay(1)
        ]))
    }

    @Test("two fingers lower to idb's two-finger touch at both points")
    func twoFingers() throws {
        let event = try InputEvent.twoFingerTouch(direction: .down, x1: 10, y1: 20, x2: 70, y2: 20).hidEvent()
        guard case let .twoFingerTouch(direction, finger1, finger2) = event else {
            Issue.record("expected a two-finger touch, got \(event)")
            return
        }
        #expect(direction == .down)
        #expect(finger1 == CGPoint(x: 10, y: 20) && finger2 == CGPoint(x: 70, y: 20))
        #expect(InputEvent.composite([.delay(1), .twoFingerTouch(direction: .up, x1: 1, y1: 1, x2: 2, y2: 1)]).hasTwoFingers)
        #expect(!InputEvent.composite([.touch(direction: .down, x: 1, y: 1)]).hasTwoFingers)
    }
}
