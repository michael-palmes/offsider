import Foundation
import Testing
@testable import Offsider

@Suite("Metro status")
struct MetroStatusTests {
    @Test("running is HTTP 200 with Metro's own body; anything else, or no answer, is a problem")
    func answers() async {
        let running = MetroStatus(fetch: { _, _ in (200, Data("packager-status:running".utf8)) })
        #expect(await running.problem(port: 8742) == nil)
        let other = MetroStatus(fetch: { _, _ in (200, Data("<html>".utf8)) })
        #expect(await other.problem(port: 8742) == "something else answered on that port")
        let refused = MetroStatus(fetch: { _, _ in throw URLError(.cannotConnectToHost) })
        #expect(await refused.problem(port: 8743) == "nothing answered within 2 s")
    }

    @Test("the request always goes to loopback, with a 2 s timeout")
    func loopbackOnly() async {
        let seen = Recorder()
        _ = await MetroStatus(fetch: { url, timeout in
            await seen.record(url, timeout)
            return (200, Data("packager-status:running".utf8))
        }).problem(port: 19000)
        let (url, timeout) = await seen.value
        #expect(url?.absoluteString == "http://127.0.0.1:19000/status")
        #expect(timeout == 2)
    }

    actor Recorder {
        var value: (URL?, TimeInterval?) = (nil, nil)
        func record(_ url: URL, _ timeout: TimeInterval) { value = (url, timeout) }
    }
}
