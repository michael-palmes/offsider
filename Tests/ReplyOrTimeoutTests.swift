import Foundation
import OffsiderCore
import Testing

/// Keeps the reply callback `replyOrTimeout` hands out, to call after it returns.
private final class HeldAnswer: @unchecked Sendable {
    private let lock = NSLock()
    private var answer: (@Sendable (String) -> Void)?

    func keep(_ answer: @escaping @Sendable (String) -> Void) { lock.withLock { self.answer = answer } }
    func call(_ value: String) { lock.withLock { answer }?(value) }
}

@Suite("Reply or timeout")
struct ReplyOrTimeoutTests {
    @Test("exactly one of many concurrent claims wins")
    func onceFlag() async {
        let flag = OnceFlag()
        let wins = await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<64 { group.addTask { flag.claim() } }
            return await group.reduce(0) { $0 + ($1 ? 1 : 0) }
        }
        #expect(wins == 1)
        #expect(!flag.claim())
    }

    @Test("a reply before the deadline is returned without waiting it out")
    func replyFirst() async {
        let started = ContinuousClock.now
        let value = await replyOrTimeout(within: 60, timedOut: "timed out") { answer in answer("reply") }
        #expect(value == "reply")
        #expect(ContinuousClock.now - started < .seconds(30))
    }

    @Test("with no reply the timeout value comes back, and a reply after it is ignored")
    func timeoutFirst() async {
        let held = HeldAnswer()
        let value = await replyOrTimeout(within: 0.05, timedOut: "timed out") { answer in held.keep(answer) }
        #expect(value == "timed out")
        held.call("late")
    }
}
