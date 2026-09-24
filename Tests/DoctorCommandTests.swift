import Darwin
import Foundation
import Testing
@testable import Offsider

@Suite("Doctor Command Tests")
struct DoctorCommandTests {
    private static let hostCheckIDs: Set<String> = [
        "xcode.developer-dir",
        "xcode.version",
        "hid.stabilization",
        "hid.broker-dir",
        "simulators.booted",
    ]

    private func parseReport(_ stdout: String) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: Data(stdout.utf8))
        return try #require(object as? [String: Any])
    }

    private func checks(_ report: [String: Any]) throws -> [[String: Any]] {
        try #require(report["checks"] as? [[String: Any]])
    }

    private func check(_ id: String, in report: [String: Any]) throws -> [String: Any] {
        try #require(try checks(report).first { $0["id"] as? String == id })
    }

    private func expectedExitCode(for status: String?) -> Int32? {
        ["pass": 0, "warn": 3, "fail": 4][status ?? ""]
    }

    @Test("--json prints only one JSON report on stdout and the human text on stderr")
    func jsonReportOnStdout() async throws {
        let result = try await TestHelpers.runOffsiderCommandSeparated("doctor --json")
        let report = try parseReport(result.stdout)
        let ids = Set(try checks(report).compactMap { $0["id"] as? String })

        #expect(Self.hostCheckIDs.isSubset(of: ids))
        #expect(!ids.contains { $0.hasPrefix("simulator.") })
        #expect(report["udid"] is NSNull)
        #expect((report["fixes"] as? [Any])?.isEmpty == true)
        #expect(result.exitCode == expectedExitCode(for: report["status"] as? String))
        #expect(result.stderr.contains("Offsider doctor: Xcode"))
        #expect(result.stderr.contains("✓ xcode.developer-dir"))
        #expect(!result.stdout.contains("Offsider doctor:"))
    }

    @Test("Without --json the human report goes to stdout")
    func humanReportOnStdout() async throws {
        let result = try await TestHelpers.runOffsiderCommandSeparated("doctor")
        #expect(result.stdout.hasPrefix("Offsider doctor: Xcode"))
        #expect(result.stdout.contains("hid.broker-dir"))
        #expect(result.stdout.contains("Result: "))
        #expect([0, 3, 4].contains(result.exitCode))
    }

    @Test("An unusable stabilisation value warns and exits with at least 3")
    func invalidStabilizationWarns() async throws {
        let result = try await TestHelpers.runOffsiderCommandSeparated(
            "doctor --json",
            environment: ["OFFSIDER_HID_STABILIZATION_MS": "abc"]
        )
        let report = try parseReport(result.stdout)
        #expect(try check("hid.stabilization", in: report)["status"] as? String == "warn")
        #expect(try check("hid.stabilization", in: report)["hint"] as? String != nil)
        #expect(result.exitCode >= 3)
    }

    @Test("An unknown simulator fails simulator.state and exits 4")
    func unknownSimulatorFails() async throws {
        let udid = "00000000-0000-0000-0000-000000000000"
        let result = try await TestHelpers.runOffsiderCommandSeparated("doctor --json", simulatorUDID: udid)
        let report = try parseReport(result.stdout)
        #expect(report["udid"] as? String == udid)
        let state = try check("simulator.state", in: report)
        #expect(state["status"] as? String == "fail")
        #expect((state["detail"] as? String)?.contains(udid) == true)
        #expect(try check("simulator.hid-transport", in: report)["status"] as? String == "skip")
        #expect(result.exitCode == 4)
    }

    @Test("Report mode leaves an absent HID broker directory absent")
    @MainActor
    func reportModeHasNoSideEffects() async throws {
        let brokerDirectory = HIDBroker.brokerRootPath()
        let existedBefore = FileManager.default.fileExists(atPath: brokerDirectory)

        let result = try await TestHelpers.runOffsiderCommandSeparated("doctor --json")
        let broker = try check("hid.broker-dir", in: try parseReport(result.stdout))

        #expect(broker["status"] as? String != nil)
        if !existedBefore {
            #expect(broker["detail"] as? String == "Not created yet")
            #expect(!FileManager.default.fileExists(atPath: brokerDirectory))
        }
    }

    @Test("The broker directory probe creates nothing and counts stale sockets")
    @MainActor
    func brokerProbeCountsStaleSockets() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("offsider-doctor-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(DoctorProbes.brokerDirectoryState(path: root.path) == .absent)
        #expect(!FileManager.default.fileExists(atPath: root.path))

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let socket = root.appendingPathComponent("abc-def-v2.sock").path
        FileManager.default.createFile(atPath: socket, contents: nil)
        FileManager.default.createFile(atPath: root.appendingPathComponent("notes.txt").path, contents: nil)

        #expect(DoctorProbes.brokerDirectoryState(path: root.path) == .healthy(live: 0, stale: 1, unexpectedEntries: ["notes.txt"]))
        #expect(!FileManager.default.fileExists(atPath: socket + ".lifetime.lock"))

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
        #expect(DoctorProbes.brokerDirectoryState(path: root.path) == .unsafe(reason: "group or other users can access it", ownedByCurrentUser: true))
    }
}
