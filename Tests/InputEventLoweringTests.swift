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
        #expect(Set(HardwareButton.allCases.map(\.hidButton)) == Set(FBSimulatorHIDButton.allCases))
    }

    @Test("directions lower to idb directions")
    func directionsLowerToIDBDirections() {
        #expect(InputDirection.down.hidDirection == .down)
        #expect(InputDirection.up.hidDirection == .up)
    }

    @Test("single events lower to the idb events commands dispatch")
    func singleEventsLowerToIDBEvents() {
        #expect(InputEvent.tapAt(x: 10, y: 20).hidEvent == .composite([
            .touch(direction: .down, x: 10, y: 20),
            .touch(direction: .up, x: 10, y: 20)
        ]))
        #expect(InputEvent.touch(direction: .down, x: 1.5, y: 2.5).hidEvent == .touch(direction: .down, x: 1.5, y: 2.5))
        #expect(InputEvent.touch(direction: .up, x: 3, y: 4).hidEvent == .touch(direction: .up, x: 3, y: 4))
        #expect(InputEvent.button(direction: .down, button: .lock).hidEvent == .button(direction: .down, button: .lock))
        #expect(InputEvent.shortButtonPress(.home).hidEvent == .composite([
            .button(direction: .down, button: .homeButton),
            .button(direction: .up, button: .homeButton)
        ]))
        #expect(InputEvent.keyboard(direction: .up, keyCode: 225).hidEvent == .keyboard(direction: .up, keyCode: 225))
        #expect(InputEvent.shortKeyPress(40).hidEvent == .composite([
            .keyboard(direction: .down, keyCode: 40),
            .keyboard(direction: .up, keyCode: 40)
        ]))
        #expect(InputEvent.delay(0.25).hidEvent == .delay(0.25))
    }

    @Test("swipes lower to the idb swipe expansion")
    func swipesLowerToIDBSwipeExpansion() {
        let lowered = InputEvent.swipe(100, yStart: 600, xEnd: 100, yEnd: 200, delta: 50, duration: 1).hidEvent

        #expect(lowered == .swipe(100, yStart: 600, xEnd: 100, yEnd: 200, delta: 50, duration: 1))
        guard case let .composite(events) = lowered else {
            Issue.record("A swipe must lower to a composite of touches")
            return
        }
        #expect(events.first == .touch(direction: .down, x: 100, y: 600))
        #expect(events.last == .touch(direction: .up, x: 100, y: 200))
    }

    @Test("nested composites keep their order and nesting")
    func nestedCompositesKeepOrderAndNesting() {
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

        #expect(event.hidEvent == .composite([
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
}
