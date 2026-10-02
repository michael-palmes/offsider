import ArgumentParser
import Foundation
import OffsiderCore
import Testing
@testable import Offsider

@Suite("Batch read steps")
@MainActor
struct BatchReadStepTests {
    private static let device = DeviceID(rawValue: "fake-device", platform: .ios)
    private static let screen = UIScreenInfo(width: 402, height: 874, scale: 1, orientation: .portrait)

    private static let closed = FakeUI.tree([
        FakeUI.node(.button, id: "open", label: "Open", frame: FakeUI.frame(20, 100, 350, 44)),
        FakeUI.node(.text, id: "state", label: "State", value: "Closed", frame: FakeUI.frame(20, 200, 200, 30)),
    ])
    private static let opened = FakeUI.tree([
        FakeUI.node(.text, id: "sheet-title", label: "Sheet", frame: FakeUI.frame(20, 400, 350, 44)),
        FakeUI.node(.text, id: "state", label: "State", value: "Open", frame: FakeUI.frame(20, 200, 200, 30)),
    ])

    private final class Captured {
        var out = ""
        var err = ""

        /// stdout split into parsed NDJSON objects.
        func records() throws -> [[String: Any]] {
            try out.split(separator: "\n").map { line in
                try #require(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
            }
        }
    }

    private static func png() throws -> Data {
        try ScreenImage.encode(TestImages.make(width: 40, height: 40), as: .png)
    }

    private static func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("offsider-batch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @discardableResult
    private static func run(
        _ steps: [String],
        on backend: FakeDeviceBackend,
        json: Bool = false,
        continueOnError: Bool = false,
        captured: Captured,
        waitTimeout: TimeInterval = 0
    ) async throws -> [BatchStepRecord] {
        let context = BatchContext(
            backend: backend,
            device: device,
            axCachePolicy: .perBatch,
            typeSubmissionMode: .chunked,
            typeChunkSize: 200,
            waitTimeout: waitTimeout
        )
        let output = BatchOutput(json: json, write: { captured.out += $0 }, writeError: { captured.err += $0 })
        return try await Batch.runSteps(
            steps, context: context, session: backend.session, continueOnError: continueOnError, output: output, logger: OffsiderLogger()
        )
    }

    /// Runs and returns the exit code the batch would end with: 0, 5 (`ExitCode`) or 1 (`CLIError`).
    private static func exitCode(
        _ steps: [String],
        on backend: FakeDeviceBackend,
        json: Bool = false,
        continueOnError: Bool = false,
        captured: Captured,
        waitTimeout: TimeInterval = 0
    ) async throws -> Int32 {
        do {
            try await run(steps, on: backend, json: json, continueOnError: continueOnError, captured: captured, waitTimeout: waitTimeout)
            return 0
        } catch let exit as ExitCode {
            return exit.rawValue
        } catch let error as CLIError {
            captured.err += error.userFacingDescription
            return 1
        }
    }

    @Test("one batch taps, waits, asserts, captures and reads the tree, with one NDJSON line per step and a summary")
    func wholeCaseAsNDJSON() async throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let shot = directory.appendingPathComponent("shot.png").path
        let backend = FakeDeviceBackend(trees: [Self.closed, Self.opened], screenshots: [try Self.png()], screen: Self.screen, advanceTreeOnInput: true)
        let captured = Captured()

        try await Self.run([
            "tap --id open",
            "wait --id sheet-title --timeout 1",
            "assert --id state --has-value Open",
            "screenshot --output '\(shot)'",
            "describe-ui --summary",
        ], on: backend, json: true, captured: captured)

        let lines = captured.out.split(separator: "\n").map(String.init)
        let records = try captured.records()
        #expect(lines.count == 6)
        #expect(lines[0].hasPrefix(#"{"step":1,"kind":"tap","line":"tap --id open","ok":true,"ms":"#))
        #expect(records.map { $0["kind"] as? String } == ["tap", "wait", "assert", "screenshot", "describe-ui", "batch"])
        #expect(records.dropLast().allSatisfy { $0["ok"] as? Bool == true && $0["error"] == nil })
        #expect(records[1]["met"] as? Bool == true && records[1]["reason"] as? String == "on screen")
        #expect((records[1]["match"] as? [String: Any])?["id"] as? String == "sheet-title")
        #expect((records[2]["match"] as? [String: Any])?["value"] as? String == "Open")
        #expect(records[3]["path"] as? String == shot && records[3]["width"] as? Int == 40)
        #expect((records[4]["output"] as? String)?.contains("sheet-title") == true)
        #expect(lines[5].hasPrefix(#"{"step":null,"kind":"batch","ok":true,"ms":"#))
        #expect(lines[5].hasSuffix(#","steps":5,"failed":0}"#))
        #expect(backend.session.calls == [.perform(.tapAt(x: 195, y: 122))])
    }

    @Test("without --json, read steps print their standalone output and input steps print nothing")
    func humanOutput() async throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let shot = directory.appendingPathComponent("shot.png").path
        let backend = FakeDeviceBackend(trees: [Self.closed, Self.opened], screenshots: [try Self.png()], screen: Self.screen, advanceTreeOnInput: true)
        let captured = Captured()

        try await Self.run([
            "tap --id open",
            "assert --id state --has-value Open",
            "screenshot --output '\(shot)'",
            "describe-ui --summary",
        ], on: backend, captured: captured)

        let lines = captured.out.split(separator: "\n").map(String.init)
        #expect(lines.first == "✓ --id 'state' is on screen with value 'Open'")
        #expect(lines.dropFirst().first == shot)
        #expect(captured.out.contains("sheet-title"))
        #expect(!captured.out.contains(#""step""#))
        #expect(FileManager.default.fileExists(atPath: shot))
    }

    @Test("a failed assert under --continue-on-error runs later steps and exits 5")
    func failedAssertExitsFive() async throws {
        let backend = FakeDeviceBackend(trees: [Self.closed])
        let captured = Captured()

        let code = try await Self.exitCode(
            ["assert --id state --has-value Open", "key 40"], on: backend, json: true, continueOnError: true, captured: captured
        )

        #expect(code == 5)
        let records = try captured.records()
        #expect(records[0]["ok"] as? Bool == false && records[0]["exitCode"] as? Int == 5)
        #expect(records[0]["error"] as? String == "Assertion failed: --id 'state' has value 'Closed', expected 'Open'.")
        #expect(records[0]["met"] as? Bool == false)
        #expect(records.last?["failed"] as? Int == 1)
        #expect(captured.err.contains("Batch completed with 1 failure(s):\nStep 1 failed: [assert] -> Assertion failed:"))
        #expect(backend.session.calls == [.perform(.shortKeyPress(40))])
    }

    @Test("a failed assert with a step that cannot run exits 1")
    func runFailureOutranksConditionFailure() async throws {
        let backend = FakeDeviceBackend(trees: [Self.closed])
        let captured = Captured()

        let code = try await Self.exitCode(
            ["assert --id state --has-value Open", "unknown-command"], on: backend, json: true, continueOnError: true, captured: captured
        )

        #expect(code == 1)
        let records = try captured.records()
        #expect(records.map { $0["exitCode"] as? Int } == [5, 1, nil])
        #expect(captured.err.contains("Step 2 failed: [unknown-command] -> Unsupported batch step 'unknown-command'."))
    }

    @Test("without --continue-on-error a failed wait stops the batch with exit 5")
    func failedWaitStopsBatch() async throws {
        let backend = FakeDeviceBackend(trees: [Self.closed])
        let captured = Captured()

        let code = try await Self.exitCode(["wait --id sheet-title --timeout 0", "key 40"], on: backend, json: true, captured: captured)

        #expect(code == 5)
        #expect(backend.session.calls.isEmpty)
        let records = try captured.records()
        #expect(records.count == 2)
        #expect(records[0]["error"] as? String == "Timed out after 0 s waiting for --id 'sheet-title' (last: not found).")
        #expect(records[1]["ok"] as? Bool == false && records[1]["steps"] as? Int == 2 && records[1]["failed"] as? Int == 1)
        #expect(captured.err == "Step 1 failed: [wait]\nTimed out after 0 s waiting for --id 'sheet-title' (last: not found).\n")
    }

    @Test("a wait met after polling shares its last tree with the next selector tap")
    func waitThenTapSharesTree() async throws {
        let backend = FakeDeviceBackend(trees: [FakeUI.tree([]), Self.closed])
        let captured = Captured()

        try await Self.run(["wait --id open --timeout 2 --poll-interval 0.05", "tap --id open"], on: backend, captured: captured)

        #expect(backend.treeReads == 2)
        #expect(backend.session.calls == [.perform(.tapAt(x: 195, y: 122))])
    }

    @Test("an assert and a describe-ui with no input between them read the tree once")
    func readStepsShareTree() async throws {
        let backend = FakeDeviceBackend(trees: [Self.closed, Self.opened])
        let captured = Captured()

        try await Self.run(["assert --id open", "describe-ui --summary", "tap --id open"], on: backend, captured: captured)

        #expect(backend.treeReads == 1)
        #expect(!captured.out.contains("sheet-title"))
    }

    @Test("a describe-ui step renders exactly as the standalone command does")
    func describeMatchesStandalone() async throws {
        var expected = Self.closed
        expected.screen = Self.screen

        for options in [["--summary"], ["--format", "ndjson", "--on-screen"]] {
            let captured = Captured()
            try await Self.run(["describe-ui " + options.joined(separator: " ")], on: FakeDeviceBackend(trees: [Self.closed], screen: Self.screen), captured: captured)
            let standalone = String(decoding: try DescribeUIOutputOptions.parse(options).render(expected), as: UTF8.self)
            #expect(captured.out == standalone)

            let jsonCaptured = Captured()
            try await Self.run(["describe-ui " + options.joined(separator: " ")], on: FakeDeviceBackend(trees: [Self.closed], screen: Self.screen), json: true, captured: jsonCaptured)
            #expect(try jsonCaptured.records()[0]["output"] as? String == standalone)
        }

        let captured = Captured()
        try await Self.run(["describe-ui --flat"], on: FakeDeviceBackend(trees: [Self.closed], screen: Self.screen), json: true, captured: captured)
        let tree = try #require(try captured.records()[0]["tree"] as? NSDictionary)
        let standalone = try DescribeUIOutputOptions.parse(["--flat"]).render(expected)
        #expect(tree == (try JSONSerialization.jsonObject(with: standalone) as? NSDictionary))
    }

    @Test("an unchanged screenshot --compare fails the step with exit 5")
    func unchangedCompareExitsFive() async throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let baseline = directory.appendingPathComponent("baseline.png")
        try Self.png().write(to: baseline)
        let captured = Captured()

        let code = try await Self.exitCode(
            ["screenshot --compare '\(baseline.path)'"], on: FakeDeviceBackend(trees: [], screenshots: [try Self.png()]), json: true, captured: captured
        )

        #expect(code == 5)
        let record = try captured.records()[0]
        #expect(record["changed"] as? Bool == false && record["exitCode"] as? Int == 5)
        #expect((record["error"] as? String)?.hasPrefix("Unchanged: ") == true)
    }

    @Test("a tap step's own --wait-timeout overrides the batch-level value")
    func stepWaitTimeoutOverrides() async throws {
        let trees = [FakeUI.tree([]), FakeUI.tree([]), Self.closed]

        let ignored = FakeDeviceBackend(trees: trees)
        let code = try await Self.exitCode(["tap --id open"], on: ignored, captured: Captured())
        #expect(code == 1)

        let honoured = FakeDeviceBackend(trees: trees)
        try await Self.run(["tap --id open --wait-timeout 30 --poll-interval 0.01"], on: honoured, captured: Captured())
        #expect(honoured.session.calls == [.perform(.tapAt(x: 195, y: 122))])

        let disabled = FakeDeviceBackend(trees: trees)
        let disabledCode = try await Self.exitCode(["tap --id open --wait-timeout 0"], on: disabled, captured: Captured(), waitTimeout: 2)
        #expect(disabledCode == 1)
        #expect(disabled.treeReads == 1)
    }

    @Test("--json on a step is refused with a pointer to batch --json")
    func stepJSONRejected() async throws {
        let captured = Captured()
        let code = try await Self.exitCode(["wait --id open --json"], on: FakeDeviceBackend(trees: [Self.closed]), captured: captured)

        #expect(code == 1)
        #expect(captured.err.contains("Batch steps do not take --json. Use batch --json for one JSON line per step."))
        #expect(throws: ValidationError.self) { try BatchStepParser.rejectUnsupportedFlags(["tap", "--id", "x", "--json"]) }
    }
}
