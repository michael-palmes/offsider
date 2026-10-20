import Foundation
@testable import Offsider
@testable import OffsiderAndroid
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

    static func helper(_ serial: String) -> WarmHelperStatus {
        WarmHelperStatus(serial: serial, state: "ready", brokerPid: 33, helperPid: 4567, startedAt: started, idleSeconds: 60, idleFor: 12)
    }

    @Test("a warm Android helper gets its own row: its broker, its device pid and how long it has idled")
    func warmHelperRow() throws {
        let rows = DeviceSessionRow.rows(runners: [Self.runner("A")], brokers: [], helpers: [Self.helper("emulator-5554")])
        let text = DeviceSessionRow.text(rows)
        #expect(text.contains("emulator-5554\n  helper  ready  pid 33  device pid 4567"))
        #expect(text.contains("idle 12 s of 60 s"))
        let object = try #require(try JSONSerialization.jsonObject(with: Data(DeviceSessionRow.json(rows).utf8)) as? [String: Any])
        let sessions = try #require(object["sessions"] as? [[String: Any]])
        #expect(sessions.map { $0["device"] as? String } == ["A", "emulator-5554"])
        #expect(sessions[0]["helper"] is NSNull)
        let helper = try #require(sessions[1]["helper"] as? [String: Any])
        #expect(helper["devicePid"] as? Int == 4567 && helper["pid"] as? Int == 33 && helper["idleFor"] as? Int == 12)
        #expect(sessions[1]["runner"] is NSNull && sessions[1]["broker"] is NSNull)
    }

    @Test("stop JSON says when a device's warm helper was stopped")
    func stopHelperJSON() throws {
        let text = DeviceSessionRow.stoppedJSON(DeviceSessionRow.stopped(runners: [], brokers: [], helpers: ["emulator-5554"]))
        let object = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        let stopped = try #require(object["stopped"] as? [[String: Any]])
        #expect(stopped.count == 1)
        #expect(stopped[0]["helper"] as? Bool == true && stopped[0]["runner"] as? Bool == false)
    }

    @Test("a simulator's warm input session gets its own row: its broker, attached commands and how long it has idled")
    func simulatorInputRow() throws {
        let input = HIDBrokerStatus(udid: "SIM-1", pid: 44, startedAt: Self.started.timeIntervalSince1970, idleSeconds: 60, idleFor: 7, attached: 1, state: "stopping")
        let rows = DeviceSessionRow.rows(runners: [Self.runner("A")], brokers: [], helpers: [Self.helper("emulator-5554")], inputs: [input])
        let text = DeviceSessionRow.text(rows)
        #expect(text.contains("SIM-1\n  input  stopping  pid 44  started 2027-01-15T08:00:00Z  idle 7 s of 60 s"))
        let object = try #require(try JSONSerialization.jsonObject(with: Data(DeviceSessionRow.json(rows).utf8)) as? [String: Any])
        let sessions = try #require(object["sessions"] as? [[String: Any]])
        #expect(sessions.map { $0["device"] as? String } == ["A", "SIM-1", "emulator-5554"])
        #expect(sessions[0]["input"] is NSNull && sessions[2]["input"] is NSNull)
        let fields = try #require(sessions[1]["input"] as? [String: Any])
        #expect(Set(fields.keys) == ["state", "pid", "startedAt", "idleSeconds", "idleFor", "attached"])
        #expect(fields["state"] as? String == "stopping")
        #expect(fields["pid"] as? Int == 44 && fields["attached"] as? Int == 1 && fields["idleFor"] as? Int == 7)
    }

    @Test("stop says when a simulator's input session was stopped")
    func stopInputJSON() throws {
        let stopped = DeviceSessionRow.stopped(runners: [], brokers: [], inputs: ["SIM-1"])
        let object = try #require(try JSONSerialization.jsonObject(with: Data(DeviceSessionRow.stoppedJSON(stopped).utf8)) as? [String: Any])
        let entries = try #require(object["stopped"] as? [[String: Any]])
        #expect(entries.count == 1 && entries[0]["input"] as? Bool == true && entries[0]["helper"] as? Bool == false)
    }

    @Test("nested session commands keep their parent in the command path")
    func paths() throws {
        #expect(CommandPath.of(try SessionStatus.parse([])) == "session status")
        #expect(CommandPath.of(try DeviceSessionServe.parse(["--device", "U"])) == "device-session serve")
    }
}
