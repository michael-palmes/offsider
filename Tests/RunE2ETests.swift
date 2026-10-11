import CoreGraphics
import Foundation
import OffsiderCore
import Testing

/// An evidence run on a real device: three captures numbered 001 to 003 with three manifest lines. Runs use an explicit
/// `OFFSIDER_RUN` folder, since a test's parent processes are not a stable session.
enum RunE2E {
    struct Summary: Decodable {
        struct Entry: Decodable {
            let n: Int?
            let file: String?
            let command: String
            let step: Int?
            let exit: Int
            let changed: Bool?
            let expect: String?
            let diff: String?
        }
        let dir: String
        let entries: [Entry]
        let files: Int
        let failures: Int
        let unrecorded: [String]
    }

    /// Starts a run in a fresh folder, calls `capture` with the environment that joins it, stops it and returns the summary.
    static func record(_ capture: ([String: String]) async throws -> Void) async throws -> (summary: Summary, folder: String) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("offsider-run-e2e-\(UUID().uuidString)").path
        let environment = ["OFFSIDER_RUN": folder]
        let started = try await TestHelpers.runOffsiderCommandSeparated("run start '\(folder)' --label e2e", environment: environment)
        try #require(started.exitCode == 0, "run start: \(started.stderr)")
        do {
            try await capture(environment)
        } catch {
            _ = try? await TestHelpers.runOffsiderCommandSeparated("run stop", environment: environment)
            throw error
        }
        let stopped = try await TestHelpers.runOffsiderCommandSeparated("run stop --summary --json", environment: environment)
        try #require(stopped.exitCode == 0, "run stop: \(stopped.stderr)")
        return (try JSONDecoder().decode(Summary.self, from: Data(stopped.stdout.utf8)), folder)
    }

    static func checkThreeCaptures(_ summary: Summary, folder: String) throws {
        #expect(summary.entries.map(\.n) == [1, 2, 3])
        #expect(summary.entries.map(\.command) == ["screenshot", "logs", "batch"])
        #expect(summary.entries.last?.step == 1)
        #expect(summary.entries.allSatisfy { $0.exit == 0 })
        #expect(summary.files == 3 && summary.failures == 0 && summary.unrecorded.isEmpty)
        let names = try FileManager.default.contentsOfDirectory(atPath: folder).filter { $0.first?.isNumber == true }.sorted()
        #expect(names.count == 3)
        #expect(names.map { String($0.prefix(4)) } == ["001-", "002-", "003-"])
        #expect(names.allSatisfy { $0.range(of: #"^\d{3}-(screenshot|logs)-\d{2}\.\d{2}\.\d{2}\.(png|log)$"#, options: .regularExpression) != nil }, "\(names)")
        let manifest = try String(contentsOfFile: folder + "/manifest.ndjson", encoding: .utf8)
        #expect(manifest.split(separator: "\n").count == 3)
        try? FileManager.default.removeItem(atPath: folder)
    }
}

@Suite("Evidence runs", .serialized, .enabled(if: isE2EEnabled))
struct RunE2ETests {
    @Test("a screenshot, a logs read and a batch screenshot step are numbered into the run")
    func threeCaptures() async throws {
        let udid = try TestHelpers.requireSimulatorUDID()
        let (summary, folder) = try await RunE2E.record { environment in
            for command in ["screenshot", "logs --process SpringBoard --last 5s", "batch --step screenshot"] {
                let result = try await TestHelpers.runOffsiderCommandSeparated(command, simulatorUDID: udid, environment: environment)
                try #require(result.exitCode == 0, "\(command): \(result.stderr)")
            }
        }
        try RunE2E.checkThreeCaptures(summary, folder: folder)
    }

    @Test("--expect unchanged passes a still screen and fails a changed one, and the run keeps a diff only for the change")
    func expectUnchanged() async throws {
        let udid = try TestHelpers.requireSimulatorUDID()
        try await TestHelpers.launchPlaygroundApp(to: "tap-test", simulatorUDID: udid)
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("offsider-expect-e2e-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let baseline = scratch.appendingPathComponent("before.png").path
        let painted = scratch.appendingPathComponent("painted.png").path
        let shot = try await TestHelpers.runOffsiderCommandSeparated("screenshot --scale points --output '\(baseline)'", simulatorUDID: udid)
        try #require(shot.exitCode == 0, "\(shot.stderr)")
        let image = try ScreenImage.decode(try Data(contentsOf: URL(fileURLWithPath: baseline)))
        let block = CGRect(x: image.width / 4, y: image.height / 2, width: image.width / 2, height: 40)
        try ScreenImage.encode(try ScreenImage.masked(image, pixelRects: [block]), as: .png).write(to: URL(fileURLWithPath: painted))

        var exits: [Int32] = []
        var lines: [String] = []
        let (summary, folder) = try await RunE2E.record { environment in
            for compare in [baseline, painted] {
                let result = try await TestHelpers.runOffsiderCommandSeparated(
                    "screenshot --scale points --json --compare '\(compare)' --expect unchanged", simulatorUDID: udid, environment: environment
                )
                exits.append(result.exitCode)
                lines.append(result.stdout)
            }
        }
        defer { try? FileManager.default.removeItem(atPath: folder) }
        #expect(exits == [0, 5], "\(lines)")
        #expect(lines.first?.contains(#""changed":false,"expected":"unchanged","met":true"#) == true)
        #expect(lines.last?.contains(#""changed":true,"expected":"unchanged","met":false"#) == true)
        #expect(summary.entries.map(\.changed) == [false, true])
        #expect(summary.entries.map(\.expect) == ["unchanged", "unchanged"])
        #expect(summary.entries.map { $0.diff != nil } == [false, true])
        let diffs = try FileManager.default.contentsOfDirectory(atPath: folder).filter { $0.hasSuffix("-diff.png") }
        #expect(diffs.count == 1)
    }
}
