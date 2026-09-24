import Foundation
import Testing
import OffsiderCore

@Suite("Doctor Report Tests")
struct DoctorReportTests {
    private func report(_ statuses: [CheckStatus], udid: String? = nil) -> DoctorReport {
        DoctorReport(
            offsiderVersion: "0.2.0",
            udid: udid,
            xcode: XcodeSummary(developerDir: nil, version: "27.0", build: nil, coreSimulator: nil),
            booted: [],
            checks: statuses.enumerated().map { index, status in
                DoctorCheckResult(id: DoctorCheckID.allCases[index], status: status, detail: "detail")
            }
        )
    }

    private func jsonObject(_ report: DoctorReport) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: try report.jsonData())
        return try #require(object as? [String: Any])
    }

    @Test("The worst status wins and skip counts as pass")
    func aggregation() {
        #expect(CheckStatus.aggregate([.pass, .warn]) == .warn)
        #expect(CheckStatus.aggregate([.pass, .warn, .fail]) == .fail)
        #expect(CheckStatus.aggregate([.pass, .skip]) == .pass)
        #expect(CheckStatus.aggregate([.skip]) == .pass)
        #expect(CheckStatus.aggregate([]) == .pass)
    }

    @Test("Exit codes are 0 for pass, 3 for warnings and 4 for failures")
    func exitCodes() {
        #expect(report([.pass, .skip]).exitCode.rawValue == 0)
        #expect(report([.pass, .warn]).exitCode.rawValue == 3)
        #expect(report([.warn, .fail]).exitCode.rawValue == 4)
    }

    @Test("JSON has exactly the documented top-level keys")
    func topLevelKeys() throws {
        let object = try jsonObject(report([.warn]))
        #expect(Set(object.keys) == ["version", "offsiderVersion", "status", "udid", "xcode", "booted", "checks", "fixes"])
        #expect(object["version"] as? Int == 1)
        #expect(object["status"] as? String == "warn")
        #expect((object["fixes"] as? [Any])?.isEmpty == true)
    }

    @Test("Missing values encode as explicit nulls")
    func explicitNulls() throws {
        let object = try jsonObject(report([.pass]))
        #expect(object["udid"] is NSNull)
        let xcode = try #require(object["xcode"] as? [String: Any])
        #expect(Set(xcode.keys) == ["developerDir", "version", "build", "coreSimulator"])
        #expect(xcode["build"] is NSNull)
        let check = try #require((object["checks"] as? [[String: Any]])?.first)
        #expect(Set(check.keys) == ["id", "title", "status", "detail", "hint", "fixable"])
        #expect(check["hint"] is NSNull)
    }

    @Test("A report with a UDID carries it")
    func udidIsEncoded() throws {
        let object = try jsonObject(report([.pass], udid: "ABC"))
        #expect(object["udid"] as? String == "ABC")
    }

    @Test("JSON keys are sorted so output is stable")
    func sortedKeys() throws {
        let text = try #require(String(data: try report([.pass]).jsonData(), encoding: .utf8))
        let booted = try #require(text.range(of: "\"booted\""))
        let version = try #require(text.range(of: "\"version\" : 1"))
        #expect(booted.lowerBound < version.lowerBound)
    }

    @Test("Check ids are the documented contract strings")
    func checkIdentifiers() {
        #expect(DoctorCheckID.allCases.map(\.rawValue) == [
            "xcode.developer-dir",
            "xcode.version",
            "xcode.frameworks",
            "coresimulator.version",
            "host.simulator-app",
            "host.device-hub",
            "hid.stabilization",
            "hid.broker-dir",
            "simulators.booted",
            "simulator.state",
            "simulator.device-window",
            "simulator.resize-mode",
            "simulator.dtuhidd",
            "simulator.dtuhidd-active-flag",
            "simulator.hid-transport",
            "simulator.accessibility",
        ])
        #expect(DoctorCheckID.allCases.filter(\.isPerSimulator).count == 7)
    }

    @Test("A report round-trips through JSON")
    func roundTrip() throws {
        let original = DoctorReport(
            offsiderVersion: "0.2.0",
            udid: nil,
            xcode: XcodeSummary(developerDir: "/dev", version: "27.0", build: "27A1", coreSimulator: "1155.4"),
            booted: [BootedSimulator(udid: "U", name: "iPhone", osVersion: "iOS 27.0", deviceType: "iPhone")],
            checks: [DoctorCheckResult(id: .deviceHub, status: .warn, detail: "d", hint: "h", fixable: true)],
            fixes: [DoctorFixResult(id: .deviceHub, action: "Open Device Hub", outcome: .applied, detail: "Opened")]
        )
        let decoded = try JSONDecoder().decode(DoctorReport.self, from: try original.jsonData())
        #expect(decoded == original)
    }
}
