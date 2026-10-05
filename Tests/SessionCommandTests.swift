import Foundation
@testable import Offsider
import OffsiderIOSDevice
import Testing

@Suite("session command")
struct SessionCommandTests {
    static let started = Date(timeIntervalSince1970: 1_800_000_000)

    static func runner(_ udid: String) -> RunnerSessionRow {
        RunnerSessionRow(
            record: RunnerSessionRecord(
                udid: udid, pid: 11, port: 40000, token: "secret-token", startedAt: started, lastUsed: started, buildKey: "k", version: "1",
                transport: .usbmux, process: nil
            ),
            alive: true
        )
    }

    static func broker(_ udid: String, reply: DeviceSessionReply?) -> DeviceSessionStatus {
        DeviceSessionStatus(
            record: DeviceSessionRecord(udid: udid, pid: 22, process: nil, socket: "/s.sock", startedAt: started, version: 1, state: .running),
            alive: true,
            reply: reply
        )
    }

    @Test("status JSON lists each device once with its runner and broker, null when absent, and never the runner token")
    func statusJSON() throws {
        var reply = DeviceSessionReply(id: 1)
        reply.stream = DeviceSessionStreamStatus(state: .live, width: 2736, height: 2064, framesReceived: 90)
        reply.touch = true
        let rows = DeviceSessionRow.rows(runners: [Self.runner("A"), Self.runner("B")], brokers: [Self.broker("B", reply: reply), Self.broker("C", reply: nil)])
        let text = DeviceSessionRow.json(rows)
        #expect(!text.contains("secret-token"))
        let object = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        let sessions = try #require(object["sessions"] as? [[String: Any]])
        #expect(sessions.map { $0["device"] as? String } == ["A", "B", "C"])
        #expect(sessions[0]["broker"] is NSNull)
        #expect(sessions[2]["runner"] is NSNull)
        let runner = try #require(sessions[1]["runner"] as? [String: Any])
        #expect(Set(runner.keys) == ["running", "pid", "port", "startedAt", "lastUsed", "version"])
        let broker = try #require(sessions[1]["broker"] as? [String: Any])
        #expect(broker["running"] as? Bool == true)
        #expect(broker["answering"] as? Bool == true)
        #expect(broker["pid"] as? Int == 22)
        #expect(broker["touch"] as? Bool == true)
        let stream = try #require(broker["stream"] as? [String: Any])
        #expect(stream["state"] as? String == "live")
        #expect(stream["width"] as? Int == 2736)
        let silent = try #require(sessions[2]["broker"] as? [String: Any])
        #expect(silent["answering"] as? Bool == false)
        #expect(silent["stream"] is NSNull)
    }

    @Test("stop JSON names what was stopped on each device")
    func stopJSON() throws {
        let text = DeviceSessionRow.stoppedJSON(DeviceSessionRow.stopped(runners: ["A"], brokers: ["A", "B"]))
        let object = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        let stopped = try #require(object["stopped"] as? [[String: Any]])
        #expect(stopped.count == 2)
        #expect(stopped[0]["device"] as? String == "A" && stopped[0]["runner"] as? Bool == true && stopped[0]["broker"] as? Bool == true)
        #expect(stopped[1]["device"] as? String == "B" && stopped[1]["runner"] as? Bool == false)
    }

    @Test("nested session commands keep their parent in the command path")
    func paths() throws {
        #expect(OffsiderCommand.path(of: try SessionStatus.parse([]), name: "status") == "session status")
        #expect(OffsiderCommand.path(of: try DeviceSessionServe.parse(["--device", "U"]), name: "serve") == "device-session serve")
    }
}
