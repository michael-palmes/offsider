import Foundation
import OffsiderCore
import Testing
@testable import OffsiderAndroid

@Suite("Android input lowering")
struct AndroidInputLoweringTests {
    private static func lower(_ event: InputEvent, down: Bool = false, scale: Double = 2.625) throws -> (steps: [AndroidInputStep], down: Bool) {
        var touchIsDown = down
        let steps = try AndroidInputLowering.steps(for: event, touchIsDown: &touchIsDown, scale: scale)
        return (steps, touchIsDown)
    }

    @Test("a tap is one tap step")
    func tap() throws {
        #expect(try Self.lower(.tapAt(x: 525, y: 1050)).steps == [.tap(AndroidPoint(x: 525, y: 1050))])
    }

    @Test("the first touch down is a down, later downs are moves, and up lifts the finger")
    func touchState() throws {
        let first = try Self.lower(.touch(direction: .down, x: 1, y: 2))
        #expect(first.steps == [.touch(.down, AndroidPoint(x: 1, y: 2))])
        #expect(first.down)

        let second = try Self.lower(.touch(direction: .down, x: 3, y: 4), down: true)
        #expect(second.steps == [.touch(.move, AndroidPoint(x: 3, y: 4))])

        let up = try Self.lower(.touch(direction: .up, x: 3, y: 4), down: true)
        #expect(up.steps == [.touch(.up, AndroidPoint(x: 3, y: 4))])
        #expect(!up.down)
    }

    @Test("a drag composite keeps its order: down, holds and moves, up")
    func drag() throws {
        let event = InputEvent.composite([
            .touch(direction: .down, x: 0, y: 0), .delay(0.1),
            .delay(0.05), .touch(direction: .down, x: 50, y: 0),
            .delay(0.05), .touch(direction: .down, x: 100, y: 0),
            .delay(0.1), .touch(direction: .up, x: 100, y: 0),
        ])
        let lowered = try Self.lower(event)
        #expect(lowered.steps == [
            .touch(.down, AndroidPoint(x: 0, y: 0)), .pause(0.1),
            .pause(0.05), .touch(.move, AndroidPoint(x: 50, y: 0)),
            .pause(0.05), .touch(.move, AndroidPoint(x: 100, y: 0)),
            .pause(0.1), .touch(.up, AndroidPoint(x: 100, y: 0)),
        ])
        #expect(!lowered.down)
    }

    @Test("swipe steps are the pixel distance over the dp delta times the scale")
    func swipeSteps() throws {
        let lowered = try Self.lower(.swipe(0, yStart: 0, xEnd: 0, yEnd: 1050, delta: 50, duration: 1), scale: 2.625)
        #expect(lowered.steps == [.swipe(from: AndroidPoint(x: 0, y: 0), to: AndroidPoint(x: 0, y: 1050), duration: 1, steps: 8)])
    }

    @Test("nested composites flatten in order and zero delays vanish")
    func nested() throws {
        let event = InputEvent.composite([.shortKeyPress(4), .composite([.delay(0), .shortButtonPress(.home)]), .delay(0.2)])
        #expect(try Self.lower(event).steps == [.key(.press, usage: 4), .button(.press, .home), .pause(0.2)])
    }

    @Test("an unsupported key anywhere in a composite throws before any step exists")
    func unsupportedKeyThrows() {
        let event = InputEvent.composite([.tapAt(x: 1, y: 1), .shortKeyPress(104)])
        let error = #expect(throws: AndroidError.self) { try Self.lower(event) }
        #expect(error?.kind == .unsupportedKey)
    }

    @Test("an iOS-only button throws")
    func unsupportedButtonThrows() {
        #expect(throws: AndroidError.self) { try Self.lower(.shortButtonPress(.siri)) }
    }
}
