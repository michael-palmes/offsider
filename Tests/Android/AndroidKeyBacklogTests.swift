import Foundation
import Testing
@testable import OffsiderAndroid

@Suite("Android key backlog")
struct AndroidKeyBacklogTests {
    @Test("the inbound queue's length is read from the dispatcher's line", arguments: [
        ("  InboundQueue: <empty>\n", 0),
        ("  InboundQueue: length=75\n", 75),
        ("InboundQueue: length=1", 1),
    ])
    func queued(output: String, length: Int) {
        #expect(AndroidKeyBacklog.queued(in: output) == length)
    }

    @Test("a missing or unreadable line is no reading", arguments: ["", "  PendingEvent: <none>\n", "  InboundQueue: length=many\n", "  InboundQueue: 3\n"])
    func unreadable(output: String) {
        #expect(AndroidKeyBacklog.queued(in: output) == nil)
    }

    @Test("the dump is filtered on the device, so recent key events never cross adb")
    func filteredOnDevice() {
        #expect(AndroidKeyBacklog.script.hasPrefix("dumpsys input | grep "))
    }

    @Test("the next read comes when the queue should have drained at the rate seen, within 20 to 500 ms")
    func pause() {
        #expect(AndroidKeyBacklog.pause(queued: 60, since: nil) == .milliseconds(50))
        #expect(AndroidKeyBacklog.pause(queued: 40, since: (queued: 60, pause: .milliseconds(50))) == .milliseconds(100))
        #expect(AndroidKeyBacklog.pause(queued: 59, since: (queued: 60, pause: .milliseconds(50))) == .milliseconds(500))
        #expect(AndroidKeyBacklog.pause(queued: 1, since: (queued: 60, pause: .milliseconds(50))) == .milliseconds(20))
        #expect(AndroidKeyBacklog.pause(queued: 70, since: (queued: 60, pause: .milliseconds(50))) == .milliseconds(50), "a growing queue gives no rate")
    }
}
