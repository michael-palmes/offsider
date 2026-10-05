import Foundation
import OffsiderCore
import Testing
@testable import OffsiderAndroid

@Suite("Helper inject plan")
struct HelperInjectPlanTests {
    static func json(_ requests: [HelperInjectPlan.Request]) throws -> [String] {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try requests.map { String(decoding: try encoder.encode(HelperValue.array($0.steps)), as: UTF8.self) }
    }

    static func plan(_ steps: [AndroidInputStep]) throws -> [HelperInjectPlan.Request] {
        var held: Set<UInt32> = []
        return try HelperInjectPlan.requests(for: steps, held: &held)
    }

    @Test("taps, touches, swipes and pauses keep logical pixels and become milliseconds on the device")
    func gestures() throws {
        let requests = try Self.plan([
            .tap(AndroidPoint(x: 10.5, y: 20)),
            .touch(.down, AndroidPoint(x: 1, y: 2)),
            .pause(0.1),
            .touch(.up, AndroidPoint(x: 1, y: 2)),
            .swipe(from: AndroidPoint(x: 0, y: 0), to: AndroidPoint(x: 0, y: 500), duration: 0.25, steps: 12),
        ])

        #expect(requests.count == 1)
        #expect(requests.first?.waitMilliseconds == 350)
        #expect(try Self.json(requests) == [
            #"[{"kind":"tap","x":10.5,"y":20},{"kind":"touch","phase":"down","pointer":0,"x":1,"y":2},{"kind":"pause","ms":100},"#
                + #"{"kind":"touch","phase":"up","pointer":0,"x":1,"y":2},"#
                + #"{"durationMs":250,"fromX":0,"fromY":0,"kind":"swipe","moves":12,"toX":0,"toY":500}]"#,
        ])
    }

    @Test("a held modifier sets its meta bits on later keys until it is released, across calls")
    func modifiers() throws {
        var held: Set<UInt32> = []
        let first = try HelperInjectPlan.requests(for: [.key(.down, usage: 225), .key(.press, usage: 4)], held: &held)
        let second = try HelperInjectPlan.requests(for: [.key(.up, usage: 225), .key(.press, usage: 4)], held: &held)

        #expect(try Self.json(first) == [#"[{"code":59,"kind":"key","meta":65,"phase":"down"},{"code":29,"kind":"key","meta":65,"phase":"press"}]"#])
        #expect(try Self.json(second) == [#"[{"code":59,"kind":"key","meta":0,"phase":"up"},{"code":29,"kind":"key","meta":0,"phase":"press"}]"#])
        #expect(held.isEmpty)
    }

    @Test("both Ctrl keys share CTRL_ON, which stays while either is down")
    func sharedMetaBit() {
        #expect(AndroidKeyMeta.state(holding: [224, 228]) == 0x7000)
        #expect(AndroidKeyMeta.state(holding: [228]) == 0x5000)
        #expect(AndroidKeyMeta.state(holding: []) == 0)
        #expect(AndroidKeyMeta.bits(for: 4) == nil)
    }

    @Test("buttons are key presses with their KEYCODE, and an iOS-only button is refused before any step")
    func buttons() throws {
        #expect(try Self.json(Self.plan([.button(.press, .back)])) == [#"[{"code":4,"kind":"key","meta":0,"phase":"press"}]"#])
        #expect(throws: AndroidError.self) { try Self.plan([.tap(AndroidPoint(x: 1, y: 1)), .button(.press, .siri)]) }
    }

    @Test("pauses longer than 30 s split into steps, and a request never waits more than 60 s")
    func longPauses() throws {
        let requests = try Self.plan([.pause(75), .tap(AndroidPoint(x: 1, y: 1))])

        #expect(requests.map(\.waitMilliseconds) == [60_000, 15_000])
        #expect(requests.map(\.steps.count) == [2, 2])
    }

    @Test("a swipe over 30 s is refused, and moves are capped at the helper's 1,000")
    func swipeLimits() throws {
        #expect(throws: AndroidError.self) {
            try Self.plan([.swipe(from: AndroidPoint(x: 0, y: 0), to: AndroidPoint(x: 1, y: 1), duration: 31, steps: 1)])
        }
        let capped = try Self.json(Self.plan([.swipe(from: AndroidPoint(x: 0, y: 0), to: AndroidPoint(x: 1, y: 1), duration: 1, steps: 5000)]))
        #expect(capped.first?.contains(#""moves":1000"#) == true)
    }

    @Test("typed text goes as text steps with Return and Tab as key presses")
    func text() throws {
        let chunks = try #require({ if case .keys(let chunks) = try AndroidTextPlan.make(for: "a b\tc\n") { return chunks } else { return nil } }())
        let requests = try HelperInjectPlan.requests(for: chunks)

        #expect(try Self.json(requests) == [
            #"[{"kind":"text","text":"a b"},{"code":61,"kind":"key","meta":0,"phase":"press"},{"kind":"text","text":"c"},{"code":66,"kind":"key","meta":0,"phase":"press"}]"#,
        ])
    }

    static func typed(_ text: String) throws -> [HelperInjectPlan.Request] {
        let chunks = try #require({ if case .keys(let chunks) = try AndroidTextPlan.make(for: text) { return chunks } else { return nil } }())
        return try HelperInjectPlan.requests(for: chunks)
    }

    @Test("a request's device time grows with its text, and a shifted character costs twice a plain one")
    func typingTimeGrows() throws {
        let short = try #require(try Self.typed("ab").first).deviceMilliseconds
        let long = try #require(try Self.typed(String(repeating: "ab", count: 100)).first).deviceMilliseconds
        let shifted = try #require(try Self.typed("AB").first).deviceMilliseconds

        #expect(short > 0)
        #expect(long == short * 100)
        #expect(shifted == short * 2)
        #expect(try Self.typed("ab\n").first?.deviceMilliseconds ?? 0 > short)
    }

    @Test("long text splits across requests, so no request's typing outgrows its timeout")
    func longTextSplits() throws {
        let text = String(repeating: "A", count: 600)
        let requests = try Self.typed(text)

        #expect(requests.map(\.textCharacters) == [256, 256, 88])
        #expect(requests.allSatisfy { $0.deviceMilliseconds <= 256 * 4 * HelperInjectPlan.keyEventMilliseconds })
        #expect(try Self.json(requests).joined().filter { $0 == "A" }.count == 600)
    }

    @Test("key presses add device time, and pauses still count against the helper's 60 s limit alone")
    func keyTime() throws {
        let requests = try Self.plan([.key(.press, usage: 4), .pause(1)])

        #expect(requests.first?.waitMilliseconds == 1_000)
        #expect(requests.first?.deviceMilliseconds ?? 0 > 1_000)
    }

    @Test("more than 2,000 steps split across requests")
    func stepLimit() throws {
        let requests = try Self.plan(Array(repeating: .tap(AndroidPoint(x: 1, y: 1)), count: 2_001))
        #expect(requests.map(\.steps.count) == [2_000, 1])
    }
}

@Suite("Android input policy")
struct AndroidInputPolicyTests {
    static func policy(_ value: String?) throws -> AndroidInputPolicy {
        try AndroidInputPolicy.policy(host: AndroidTestHost.make(environment: value.map { ["OFFSIDER_ANDROID_INPUT": $0] } ?? [:]))
    }

    @Test("OFFSIDER_ANDROID_INPUT is auto when unset or empty, and reads auto, helper and input in any case")
    func parsing() throws {
        #expect(try Self.policy(nil) == .auto)
        #expect(try Self.policy("") == .auto)
        #expect(try Self.policy("Helper") == .helper)
        #expect(try Self.policy("INPUT") == .input)
    }

    @Test("any other value is refused with the values Offsider reads")
    func refusal() {
        let error = #expect(throws: AndroidError.self) { try Self.policy("grpc") }
        #expect(error?.kind == .invalidSetting)
        #expect(error?.message == "OFFSIDER_ANDROID_INPUT is grpc, which Offsider cannot read. Use auto, helper or input, or unset it.")
    }

    @Test("two fingers go down as pointers 0 then 1 and lift 1 then 0, with the hold between them in one request")
    func twoFingers() throws {
        let fingers = [AndroidPoint(x: 100, y: 500), AndroidPoint(x: 160, y: 500)]
        let requests = try HelperInjectPlanTests.plan([.touches(.down, fingers), .pause(1), .touches(.up, fingers)])

        #expect(requests.count == 1)
        #expect(requests.first?.waitMilliseconds == 1000)
        #expect(try HelperInjectPlanTests.json(requests) == [
            #"[{"kind":"touch","phase":"down","pointer":0,"x":100,"y":500},{"kind":"touch","phase":"down","pointer":1,"x":160,"y":500},"#
                + #"{"kind":"pause","ms":1000},"#
                + #"{"kind":"touch","phase":"up","pointer":1,"x":160,"y":500},{"kind":"touch","phase":"up","pointer":0,"x":100,"y":500}]"#,
        ])
    }
}
