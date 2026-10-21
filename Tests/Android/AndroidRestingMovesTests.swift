import Foundation
import Testing
@testable import OffsiderAndroid

@Suite("Android resting finger moves")
struct AndroidRestingMovesTests {
    static let p = AndroidPoint(x: 100, y: 500)
    static let q = AndroidPoint(x: 100, y: 600)

    static func pauses(_ steps: [AndroidInputStep]) -> TimeInterval {
        steps.reduce(0) { total, step in
            if case .pause(let seconds) = step { return total + seconds }
            return total
        }
    }

    @Test("a hold reports the resting finger every 50 ms and keeps its length")
    func hold() {
        let steps = AndroidInputStep.withRestingMoves([.touch(.down, Self.p), .pause(0.3), .touch(.up, Self.p)])

        let rest: [AndroidInputStep] = [.pause(0.05), .touch(.move, Self.p)]
        #expect(steps == [.touch(.down, Self.p)] + Array(repeating: rest, count: 5).flatMap { $0 } + [.pause(0.05), .touch(.up, Self.p)])
        #expect(abs(Self.pauses(steps) - 0.3) < 1e-9)
    }

    @Test("the finger rests where it last moved, and two fingers rest together")
    func restsWhereItMoved() {
        let fingers = [Self.p, AndroidPoint(x: 160, y: 500)]
        #expect(AndroidInputStep.withRestingMoves([.touch(.down, Self.p), .touch(.move, Self.q), .pause(0.12), .touch(.up, Self.q)]) == [
            .touch(.down, Self.p), .touch(.move, Self.q), .pause(0.05), .touch(.move, Self.q), .pause(0.05), .touch(.move, Self.q), .pause(0.02), .touch(.up, Self.q),
        ])
        #expect(AndroidInputStep.withRestingMoves([.touches(.down, fingers), .pause(0.08), .touches(.up, fingers)]) == [
            .touches(.down, fingers), .pause(0.05), .touches(.move, fingers), .pause(0.03), .touches(.up, fingers),
        ])
    }

    @Test("a finger already down when the steps start rests too")
    func alreadyDown() {
        #expect(AndroidInputStep.withRestingMoves([.pause(0.1), .touch(.up, Self.p)], resting: [Self.p]) == [
            .pause(0.05), .touch(.move, Self.p), .pause(0.05), .touch(.up, Self.p),
        ])
    }

    @Test("pauses of 50 ms or less, pauses with no finger down, taps and swipes stay as they are")
    func untouched() {
        let steps: [AndroidInputStep] = [
            .pause(1), .tap(Self.p), .pause(1), .swipe(from: Self.p, to: Self.q, duration: 1, steps: 4), .pause(1),
            .touch(.down, Self.p), .pause(0.05), .touch(.move, Self.q), .pause(0.0504), .touch(.up, Self.q), .pause(1),
        ]
        #expect(AndroidInputStep.withRestingMoves(steps) == steps)
    }
}
