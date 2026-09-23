import Foundation
import Testing

@Suite("Doctor Command E2E Tests", .serialized, .enabled(if: isE2EEnabled))
struct DoctorTests {
    private func report(_ command: String, simulatorUDID: String? = nil) async throws -> (report: [String: Any], exitCode: Int32) {
        let result = try await TestHelpers.runOffsiderCommandSeparated(command, simulatorUDID: simulatorUDID, timeout: 120)
        let object = try JSONSerialization.jsonObject(with: Data(result.stdout.utf8))
        return (try #require(object as? [String: Any]), result.exitCode)
    }

    private func status(_ id: String, in report: [String: Any]) -> String? {
        (report["checks"] as? [[String: Any]])?.first { $0["id"] as? String == id }?["status"] as? String
    }

    @Test("The booted test simulator is listed")
    func bootedSimulatorIsListed() async throws {
        let udid = try TestHelpers.requireSimulatorUDID()
        let (report, _) = try await report("doctor --json")
        let booted = try #require(report["booted"] as? [[String: Any]])
        #expect(booted.contains { $0["udid"] as? String == udid })
        #expect(status("simulators.booted", in: report) == "pass")
    }

    @Test("A healthy booted simulator passes the state, transport and accessibility checks")
    func simulatorChecksPass() async throws {
        let udid = try TestHelpers.requireSimulatorUDID()
        let (report, exitCode) = try await report("doctor --json", simulatorUDID: udid)

        #expect(report["udid"] as? String == udid)
        #expect(status("simulator.state", in: report) == "pass")
        #expect(status("simulator.hid-transport", in: report) == "pass")
        #expect(status("simulator.accessibility", in: report) == "pass")
        #expect(status("simulator.dtuhidd-active-flag", in: report) != "fail")
        #expect(exitCode == 0 || exitCode == 3)
    }

    @Test("A second --fix skips the host fixes and leaves the report no worse")
    func fixIsRepeatable() async throws {
        let udid = try TestHelpers.requireSimulatorUDID()
        let (first, firstExit) = try await report("doctor --json --fix", simulatorUDID: udid)
        let (second, secondExit) = try await report("doctor --json --fix", simulatorUDID: udid)

        let fixes = try #require(second["fixes"] as? [[String: Any]])
        let outcomes = Dictionary(uniqueKeysWithValues: fixes.compactMap { fix in
            (fix["id"] as? String).map { ($0, fix["outcome"] as? String) }
        })
        #expect(Set(outcomes.keys) == ["host.device-hub", "hid.broker-dir", "simulator.device-window"])
        #expect(outcomes["host.device-hub"] == "skipped")
        #expect(outcomes["hid.broker-dir"] == "skipped")
        // Without Screen Recording permission the window cannot be seen, so opening it again only focuses it.
        #expect(outcomes["simulator.device-window"] != "failed")
        #expect((first["fixes"] as? [[String: Any]])?.contains { $0["outcome"] as? String == "failed" } == false)
        #expect(secondExit <= firstExit)
        #expect(status("simulator.state", in: second) == "pass")
    }
}
