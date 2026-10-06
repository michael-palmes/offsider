import Foundation
import OffsiderCore
import Testing
@testable import Offsider

/// A scripted process table: the session `node` (100) runs `zsh` (200), which runs `offsider` (300).
final class FakeProcesses: @unchecked Sendable {
    private let lock = NSLock()
    private var table: [Int32: (identity: ProcessIdentity, parent: Int32)] = [:]

    init() {
        add(pid: 100, name: "node", parent: 1)
        add(pid: 200, name: "zsh", parent: 100)
        add(pid: 300, name: "offsider", parent: 200)
    }

    func add(pid: Int32, name: String, parent: Int32, startTime: UInt64? = nil) {
        lock.withLock { table[pid] = (ProcessIdentity(pid: pid, startTime: startTime ?? UInt64(pid) * 1000, name: name), parent) }
    }

    func remove(pid: Int32) {
        lock.withLock { _ = table.removeValue(forKey: pid) }
    }

    var processTable: ProcessTable {
        ProcessTable { pid in self.lock.withLock { self.table[pid] } }
    }
}

/// A temp private directory, a run folder path, a scripted clock and process table.
@MainActor
final class RunFixture {
    let root: String
    let runsDirectory: String
    let processes = FakeProcesses()
    let clock = FixtureClock()
    var now: Date {
        get { clock.now }
        set { clock.now = newValue }
    }
    static let timeZone = TimeZone(secondsFromGMT: 34_200)!

    init() throws {
        root = (NSTemporaryDirectory() as NSString).appendingPathComponent("offsider-run-test-\(UUID().uuidString)")
        runsDirectory = try OffsiderPrivateDirectory.ensureSubdirectory("runs", root: root)
    }

    deinit {
        try? FileManager.default.removeItem(atPath: root)
    }

    func folder(_ name: String = "evidence") -> String {
        (root as NSString).appendingPathComponent(name)
    }

    func environment(selfPID: Int32 = 300, parentPID: Int32 = 200, variables: [String: String] = [:]) -> EvidenceRunEnvironment {
        let runs = runsDirectory
        return EvidenceRunEnvironment(
            variables: variables, runsDirectory: { runs }, processes: processes.processTable, selfPID: selfPID, parentPID: parentPID,
            now: { [clock] in clock.now }, timeZone: Self.timeZone
        )
    }

    func recorder(_ command: String, arguments: [String] = [], selfPID: Int32 = 300, variables: [String: String] = [:]) -> EvidenceRecorder {
        EvidenceRecorder(environment: environment(selfPID: selfPID, variables: variables), command: command, arguments: arguments)
    }

    /// Runs `body` as one command does: bound to `recorder`, its entries finished by `CommandScope`.
    func command(_ recorder: EvidenceRecorder, _ body: () async throws -> Void) async throws {
        try await EvidenceRecorder.$current.withValue(recorder) {
            try await CommandScope().run { try await body() }
        }
    }

    func start(_ dir: String? = nil, label: String? = nil, masks: RunMasks = RunMasks(), variables: [String: String] = [:]) throws -> RunRegistry.Started {
        try RunRegistry.start(dir ?? folder(), label: label, masks: masks, in: environment(variables: variables))
    }

    func manifest(_ dir: String? = nil) -> [RunManifestLine] {
        RunFolder(path: dir ?? folder()).manifest()
    }
}

@Suite("Evidence runs")
@MainActor
struct RunTests {
    static let device = DeviceID(rawValue: "fake-device", platform: .ios)

    static func screenshotBackend(_ children: [UINode] = []) throws -> FakeDeviceBackend {
        try ScreenshotMaskTests.backend(children)
    }

    static func screenshot(_ arguments: [String], on backend: FakeDeviceBackend) async throws -> ScreenshotReport {
        let command = try Screenshot.parse(arguments + ["--device", device.rawValue])
        let masks = command.masksWithRunDefaults(try command.maskPlan(environment: [:]))
        return try await command.take(try command.request(), on: DeviceRouter.Route(backend: backend, device: device), masks: masks)
    }

    // MARK: - Ownership

    @Test("the owner is the first ancestor that is not a shell or wrapper")
    func ownerSkipsShells() {
        let processes = FakeProcesses()
        processes.add(pid: 250, name: "timeout", parent: 200)
        processes.add(pid: 260, name: "bash", parent: 250)
        let owner = ProcessAncestry.owner(from: 260, in: processes.processTable)
        #expect(owner?.pid == 100)
        #expect(owner?.name == "node")
    }

    @Test("a command joins the run its session started, and another session's command does not")
    func membership() async throws {
        let fixture = try RunFixture()
        _ = try fixture.start()
        fixture.processes.add(pid: 500, name: "node", parent: 1)
        fixture.processes.add(pid: 600, name: "zsh", parent: 500)
        fixture.processes.add(pid: 700, name: "offsider", parent: 600)

        #expect(try RunRegistry.active(in: fixture.environment())?.folder.path == fixture.folder())
        #expect(try RunRegistry.active(in: fixture.environment(selfPID: 700, parentPID: 600)) == nil)
    }

    @Test("a pid reused by another process is not the run's owner")
    func reusedPid() throws {
        let fixture = try RunFixture()
        _ = try fixture.start()
        fixture.processes.add(pid: 100, name: "node", parent: 1, startTime: 999)
        #expect(try RunRegistry.active(in: fixture.environment()) == nil)
    }

    @Test("a run whose session has exited is ended as owner-exited and behaves as no run")
    func staleOwner() throws {
        let fixture = try RunFixture()
        _ = try fixture.start(label: "PR 123")
        fixture.processes.remove(pid: 100)

        let status = try RunRegistry.status(all: true, in: fixture.environment())
        #expect(status.runs.isEmpty)
        #expect(status.ended.map(\.endedBy) == ["owner-exited"])
        #expect(try RunFolder(path: fixture.folder()).readState()?.endedBy == "owner-exited")
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.runsDirectory).isEmpty)
    }

    @Test("OFFSIDER_RUN=off records nothing and OFFSIDER_RUN=<dir> records there with no session")
    func environmentOverrides() async throws {
        let fixture = try RunFixture()
        _ = try fixture.start()
        #expect(try RunRegistry.active(in: fixture.environment(variables: ["OFFSIDER_RUN": "off"])) == nil)

        let named = fixture.folder("named")
        let backend = try Self.screenshotBackend()
        try await fixture.command(fixture.recorder("screenshot", selfPID: 999, variables: ["OFFSIDER_RUN": named])) {
            _ = try await Self.screenshot([], on: backend)
        }
        #expect(fixture.manifest(named).map(\.n) == [1])
        #expect(fixture.manifest().isEmpty)
        #expect(throws: CLIError.self) { try fixture.start(variables: ["OFFSIDER_RUN": "off"]) }
    }

    // MARK: - Start and stop

    @Test("starting the same folder again is a no-op, and a different one is run_active")
    func startTwice() throws {
        let fixture = try RunFixture()
        let first = try fixture.start()
        #expect(!first.unchanged)
        #expect(try fixture.start().unchanged)

        let error = #expect(throws: CLIError.self) { try fixture.start(fixture.folder("other")) }
        #expect(error?.reason == .runActive)
        var info = stat()
        #expect(lstat(fixture.folder(), &info) == 0 && info.st_mode & 0o777 == 0o700)
    }

    @Test("a folder run start creates is 0700, and an existing one keeps its mode, flagged when others can write to it")
    func existingFolderMode() throws {
        func mode(_ path: String) -> mode_t {
            var info = stat()
            return lstat(path, &info) == 0 ? info.st_mode & 0o777 : 0
        }
        let fixture = try RunFixture()
        let created = try fixture.start(fixture.folder("created"))
        #expect(mode(fixture.folder("created")) == 0o700)
        #expect(!created.writableByOthers)

        let existing = fixture.folder("existing")
        try FileManager.default.createDirectory(atPath: existing, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        let kept = try RunFolder.prepare(existing)
        #expect(mode(existing) == 0o755)
        #expect(!kept.writableByOthers)

        let shared = fixture.folder("shared")
        try FileManager.default.createDirectory(atPath: shared, withIntermediateDirectories: true)
        chmod(shared, 0o777)
        let open = try RunFolder.prepare(shared)
        #expect(mode(shared) == 0o777)
        #expect(open.writableByOthers)
    }

    @Test("with OFFSIDER_RUN=<dir> naming an active run, starting it again changes nothing")
    func startTwiceWithOverride() throws {
        let fixture = try RunFixture()
        let variables = ["OFFSIDER_RUN": fixture.folder()]
        #expect(!(try fixture.start(variables: variables).unchanged))
        let again = try fixture.start(variables: variables)
        #expect(again.unchanged)
        #expect(!again.continued)
    }

    @Test("starting the active folder again adds new masks to the run and never removes one")
    func restartAddsMasks() async throws {
        let fixture = try RunFixture()
        _ = try fixture.start(masks: RunMasks(emails: true))
        let added = try fixture.start(masks: RunMasks(secure: true, ids: ["card"]))
        #expect(added.unchanged && added.addedMasks)
        let again = try fixture.start(masks: RunMasks(ids: ["card"]))
        #expect(again.unchanged && !again.addedMasks)

        let all = RunMasks(secure: true, emails: true, ids: ["card"])
        #expect(again.state.masks == all)
        #expect(try RunRegistry.active(in: fixture.environment())?.masks == all)
        #expect(try RunFolder(path: fixture.folder()).readState()?.masks == all)

        let backend = try Self.screenshotBackend([SecureTextTests.passwordField()])
        var report: ScreenshotReport?
        try await fixture.command(fixture.recorder("screenshot")) { report = try await Self.screenshot([], on: backend) }
        #expect(report?.maskedBy?[.secure] == 1)
    }

    @Test("with OFFSIDER_RUN=<dir> naming an active run, starting it again adds new masks to run.json")
    func restartAddsMasksWithOverride() throws {
        let fixture = try RunFixture()
        let variables = ["OFFSIDER_RUN": fixture.folder()]
        _ = try fixture.start(masks: RunMasks(secure: true), variables: variables)
        let again = try fixture.start(masks: RunMasks(ids: ["card"]), variables: variables)
        #expect(again.unchanged && again.addedMasks)
        #expect(try RunRegistry.active(in: fixture.environment(variables: variables))?.masks == RunMasks(secure: true, ids: ["card"]))
    }

    @Test("run start on the active folder prints the masks now in force")
    func restartPrintsMasks() async throws {
        let fixture = try RunFixture()
        let dir = fixture.folder()
        _ = try await TestHelpers.runOffsiderCommandSeparated("run start '\(dir)' --mask-emails", environment: ["OFFSIDER_RUN": dir])
        let added = try await TestHelpers.runOffsiderCommandSeparated("run start '\(dir)' --mask-id card --json", environment: ["OFFSIDER_RUN": dir])
        #expect(added.exitCode == 0)
        #expect(added.stderr.contains("Added masks to the active run in \(dir); masks now in force: email addresses and id card. To remove one, run `offsider run stop`, then start the run again."))
        #expect(added.stdout.contains(#""masks":{"secure":false,"emails":true,"ids":["card"]}"#))
        let same = try await TestHelpers.runOffsiderCommandSeparated("run start '\(dir)'", environment: ["OFFSIDER_RUN": dir])
        #expect(same.stderr.contains("A run is already active in \(dir) for this session; masks in force: email addresses and id card."))
    }

    @Test("stopping with no run active says so")
    func stopWithNone() throws {
        let fixture = try RunFixture()
        #expect(try RunRegistry.stop(in: fixture.environment()) == nil)
    }

    @Test("a stopped run's folder continues its numbering")
    func continuesNumbering() async throws {
        let fixture = try RunFixture()
        _ = try fixture.start()
        let backend = try Self.screenshotBackend()
        try await fixture.command(fixture.recorder("screenshot")) { _ = try await Self.screenshot([], on: backend) }
        _ = try RunRegistry.stop(in: fixture.environment())

        let again = try fixture.start()
        #expect(again.continued)
        #expect(again.state.next == 2)
        try await fixture.command(fixture.recorder("screenshot")) { _ = try await Self.screenshot([], on: backend) }
        #expect(fixture.manifest().map(\.n) == [1, 2])
    }

    // MARK: - Captures

    @Test("a screenshot without --output is written only into the run, and its path is the run file")
    func onlyCopyInRun() async throws {
        let fixture = try RunFixture()
        _ = try fixture.start()
        let backend = try Self.screenshotBackend()
        var report: ScreenshotReport?
        try await fixture.command(fixture.recorder("screenshot", arguments: ["--scale", "points"])) {
            report = try await Self.screenshot([], on: backend)
        }
        let line = try #require(fixture.manifest().first)
        #expect(line.file == "001-screenshot-15.11.07.png")
        #expect(report?.path == fixture.folder() + "/001-screenshot-15.11.07.png")
        #expect(report?.runFile == report?.path)
        #expect(line.args == ["--scale", "points"])
        #expect(line.exit == 0 && line.output == nil && line.platform == "ios")
    }

    @Test("a reserved entry's manifest time is the instant its file name carries, while ms still counts from its start")
    func reservedTimeMatchesName() throws {
        let fixture = try RunFixture()
        _ = try fixture.start()
        let base = fixture.now
        let recorder = fixture.recorder("screenshot")
        fixture.now = base + 0.6
        let token = try #require(try recorder.begin(device: Self.device, kind: "screenshot"))
        fixture.now = base + 1.25
        _ = try recorder.reserveFile(token, extension: "png")
        fixture.now = base + 2
        recorder.finish(token, exit: 0, reason: nil)

        let line = try #require(fixture.manifest().first)
        #expect(line.file == "001-screenshot-15.11.08.png")
        #expect(abs(line.time.timeIntervalSince(base + 1.25)) < 0.001)
        #expect(line.ms == 1400)
    }

    @Test("an entry with no file keeps its start as its manifest time")
    func unreservedTimeIsStart() throws {
        let fixture = try RunFixture()
        _ = try fixture.start()
        let base = fixture.now
        let recorder = fixture.recorder("screenshot")
        fixture.now = base + 0.6
        let token = try #require(try recorder.begin(device: Self.device, kind: "screenshot"))
        fixture.now = base + 2
        recorder.finish(token, exit: 1, reason: "mask_unproven")

        let line = try #require(fixture.manifest().first)
        #expect(line.file == nil)
        #expect(abs(line.time.timeIntervalSince(base + 0.6)) < 0.001)
    }

    @Test("an unwritable run folder fails a capture that has no other copy, and only warns beside --output")
    func unwritableRun() async throws {
        let fixture = try RunFixture()
        _ = try fixture.start()
        chmod(fixture.folder(), 0o500)
        defer { chmod(fixture.folder(), 0o700) }
        let backend = try Self.screenshotBackend()

        let error = await #expect(throws: CLIError.self) {
            try await fixture.command(fixture.recorder("screenshot")) { _ = try await Self.screenshot([], on: backend) }
        }
        #expect(error?.reason == .runUnavailable)

        let output = ScreenshotMaskTests.temporaryPath()
        defer { try? FileManager.default.removeItem(atPath: output) }
        var report: ScreenshotReport?
        try await fixture.command(fixture.recorder("screenshot")) { report = try await Self.screenshot(["--output", output], on: backend) }
        #expect(report?.path == output)
        #expect(report?.runFile == nil)
    }

    @Test("a withheld screenshot gets a manifest line with no number, and numbering stays contiguous")
    func failureKeepsNumbering() async throws {
        let fixture = try RunFixture()
        _ = try fixture.start()
        let unframed = try Self.screenshotBackend([SecureTextTests.passwordField(frame: nil)])
        let plain = try Self.screenshotBackend()

        try await fixture.command(fixture.recorder("screenshot")) { _ = try await Self.screenshot([], on: plain) }
        await #expect(throws: MaskUnproven.self) {
            try await fixture.command(fixture.recorder("screenshot")) { _ = try await Self.screenshot(["--mask-secure"], on: unframed) }
        }
        try await fixture.command(fixture.recorder("screenshot")) { _ = try await Self.screenshot([], on: plain) }

        let lines = fixture.manifest()
        #expect(lines.map(\.n) == [1, nil, 2])
        #expect(lines[1].file == nil && lines[1].exit == 1 && lines[1].reason == "mask_unproven")
    }

    @Test("run-wide masks apply to every capture, and a capture's own masks add to them")
    func runWideMasks() async throws {
        let fixture = try RunFixture()
        _ = try fixture.start(masks: RunMasks(emails: true))
        let backend = try Self.screenshotBackend([
            FakeUI.node(.text, id: "profile-email", label: "e2e@example.com", frame: FakeUI.frame(16, 100, 200, 40)),
            FakeUI.node(.text, id: "name", label: "Ada", frame: FakeUI.frame(16, 300, 200, 40)),
            SecureTextTests.passwordField(),
        ])
        var reports: [ScreenshotReport] = []
        try await fixture.command(fixture.recorder("screenshot")) { reports.append(try await Self.screenshot([], on: backend)) }
        try await fixture.command(fixture.recorder("screenshot")) { reports.append(try await Self.screenshot(["--mask-id", "name"], on: backend)) }
        try await fixture.command(fixture.recorder("screenshot")) { reports.append(try await Self.screenshot(["--mask-secure"], on: backend)) }

        #expect(reports.map(\.maskedBy) == [[.emails: 1], [.id: 1, .emails: 1], [.secure: 1, .emails: 1]])
        #expect(fixture.manifest().map(\.masked) == [1, 2, 2])
    }

    @Test("a batch screenshot step keeps the run's masks beside batch --mask-secure and its own masks")
    func runWideMasksInBatch() async throws {
        let fixture = try RunFixture()
        _ = try fixture.start(masks: RunMasks(emails: true, ids: ["name"]))
        let backend = try Self.screenshotBackend([
            FakeUI.node(.text, id: "profile-email", label: "e2e@example.com", frame: FakeUI.frame(16, 100, 200, 40)),
            FakeUI.node(.text, id: "name", label: "Ada", frame: FakeUI.frame(16, 300, 200, 40)),
            SecureTextTests.passwordField(),
        ])
        let context = BatchContext(
            backend: backend, device: Self.device, axCachePolicy: .perBatch, typeSubmissionMode: .chunked, typeChunkSize: 200, maskSecure: true
        )
        let output = BatchOutput(json: true, write: { _ in }, writeError: { _ in })
        var records: [BatchStepRecord] = []
        try await fixture.command(fixture.recorder("batch")) {
            records = try await Batch.runSteps(
                ["screenshot", "screenshot --mask-id name"], context: context, session: backend.session,
                continueOnError: true, output: output, logger: OffsiderLogger()
            )
        }
        let reports = records.compactMap { record -> ScreenshotReport? in
            if case .screenshot(let report) = record.detail { return report }
            return nil
        }
        #expect(reports.map(\.maskedBy) == [[.secure: 1, .id: 1, .emails: 1], [.secure: 1, .id: 1, .emails: 1]])
        #expect(fixture.manifest().map(\.masked) == [3, 3])
    }

    @Test("concurrent reservations under the folder lock never share a number")
    func concurrentReservations() throws {
        let fixture = try RunFixture()
        let folder = try RunFolder.prepare(fixture.folder()).folder
        let numbers = NumberBox()
        DispatchQueue.concurrentPerform(iterations: 24) { _ in
            if let number = try? folder.reserveNumber(now: Date()) { numbers.append(number) }
        }
        #expect(numbers.sorted == Array(1...24))
    }

    @Test("a batch's screenshot steps are recorded with their step, redacted line and exit code")
    func batchSteps() async throws {
        let fixture = try RunFixture()
        _ = try fixture.start()
        let backend = try Self.screenshotBackend()
        let baseline = ScreenshotMaskTests.temporaryPath()
        defer { try? FileManager.default.removeItem(atPath: baseline) }
        try ScreenshotMaskTests.whitePNG().write(to: URL(fileURLWithPath: baseline))
        let context = BatchContext(backend: backend, device: Self.device, axCachePolicy: .perBatch, typeSubmissionMode: .chunked, typeChunkSize: 200)
        let output = BatchOutput(json: true, write: { _ in }, writeError: { _ in })

        _ = try? await fixture.command(fixture.recorder("batch", arguments: ["--step", "type secret"])) {
            try await Batch.runSteps(
                ["type secret", "screenshot", "screenshot --compare \(baseline)"], context: context, session: backend.session,
                continueOnError: true, output: output, logger: OffsiderLogger()
            )
        }
        let lines = fixture.manifest()
        #expect(lines.map(\.command) == ["batch", "batch"])
        #expect(lines.map(\.step) == [2, 3])
        #expect(lines.map(\.exit) == [0, 5])
        #expect(lines[1].reason == "condition_not_met")
        #expect(lines[1].changed == false)
        #expect(lines[1].diff == "002-screenshot-15.11.07-diff.png")
        #expect(lines.allSatisfy { $0.args == nil })
        #expect(!String(decoding: try Data(contentsOf: URL(fileURLWithPath: fixture.folder() + "/manifest.ndjson")), as: UTF8.self).contains("secret"))
    }

    @Test("a screenshot's run copy and its diff are readable only by their owner, as every other run file is")
    func runFilesArePrivate() async throws {
        let fixture = try RunFixture()
        _ = try fixture.start()
        let backend = try Self.screenshotBackend()
        let baseline = ScreenshotMaskTests.temporaryPath()
        defer { try? FileManager.default.removeItem(atPath: baseline) }
        try ScreenshotMaskTests.whitePNG().write(to: URL(fileURLWithPath: baseline))
        let context = BatchContext(backend: backend, device: Self.device, axCachePolicy: .perBatch, typeSubmissionMode: .chunked, typeChunkSize: 200)
        let output = BatchOutput(json: true, write: { _ in }, writeError: { _ in })

        _ = try? await fixture.command(fixture.recorder("batch")) {
            try await Batch.runSteps(
                ["screenshot --compare \(baseline)"], context: context, session: backend.session,
                continueOnError: true, output: output, logger: OffsiderLogger()
            )
        }
        let line = try #require(fixture.manifest().first)
        let names = [try #require(line.file), try #require(line.diff)]
        for name in names {
            let mode = try FileManager.default.attributesOfItem(atPath: fixture.folder() + "/" + name)[.posixPermissions] as? Int
            #expect(mode == 0o600, "\(name)")
        }
    }

    @Test("a logs run file holds exactly what went to stdout, and the line counts entries and redactions")
    func logsTee() async throws {
        let fixture = try RunFixture()
        _ = try fixture.start()
        let backend = FakeLogBackend(entries: [LogEntry(message: #"login {"password":"hunter22"}"#), LogEntry(message: "plain")])
        var stdout: [String] = []
        try await fixture.command(fixture.recorder("logs", arguments: ["--json"])) {
            try await Logs.parse(["--json", "--device", "emulator-5554"])
                .read(from: DeviceRouter.Route(backend: backend, device: DeviceID(rawValue: "emulator-5554", platform: .android))) { stdout.append($0) }
        }
        let line = try #require(fixture.manifest().first)
        #expect(line.file == "001-logs-15.11.07.json")
        let file = try String(contentsOfFile: fixture.folder() + "/" + (line.file ?? ""), encoding: .utf8)
        #expect(file == stdout.map { $0 + "\n" }.joined())
        #expect(line.entries == 2 && line.redacted == 1)
    }

    @Test("a run copy whose writes fail stops being written after one report, and stdout gets every line")
    func logsTeeWriteFails() throws {
        let fixture = try RunFixture()
        let path = fixture.folder("readonly.log")
        try FileManager.default.createDirectory(atPath: fixture.root, withIntermediateDirectories: true)
        #expect(FileManager.default.createFile(atPath: path, contents: Data()))
        let readOnly = try #require(FileHandle(forReadingAtPath: path))
        var stdout: [String] = []
        var failures = 0
        let tee = RunLogTee(stdout: { stdout.append($0) }, runFile: readOnly) { _ in failures += 1 }
        for line in ["one", "two", "three"] { tee.write(line) }
        tee.close()

        #expect(stdout == ["one", "two", "three"])
        #expect(failures == 1)
    }

    // MARK: - Summaries

    @Test("the summary lists each entry, failures and unrecorded files")
    func goldenTimeline() throws {
        let fixture = try RunFixture()
        let started = Date(timeIntervalSince1970: 1_791_178_867)
        let state = RunState(label: "PR 123", startedAt: started, stoppedAt: started + 1903, next: 4)
        let entries = [
            RunManifestLine(n: 1, file: "001-screenshot-15.13.22.png", command: "screenshot", device: "emulator-5554", time: started + 135, ms: 412, exit: 0, masked: 2),
            RunManifestLine(command: "screenshot", device: "emulator-5554", time: started + 200, ms: 98, exit: 1, reason: "mask_unproven"),
            RunManifestLine(n: 2, file: "002-logs-15.16.00.log", command: "logs", device: "emulator-5554", time: started + 293, ms: 1200, exit: 0, entries: 14, redacted: 3),
            RunManifestLine(n: 3, file: "003-screenshot-15.17.00.png", command: "batch", step: 4, line: "screenshot", device: "emulator-5554", time: started + 353, ms: 300, exit: 0),
        ]
        let timeline = RunTimeline(dir: "/tmp/run", state: state, entries: entries, unrecorded: ["004-screenshot-15.20.00.png"])

        #expect(timeline.text(now: started, timeZone: RunFixture.timeZone) == """
        Run "PR 123" in /tmp/run, 15:11:07 to 15:42:50 (31 min 43 s)
        001 15:13:22 screenshot emulator-5554 ok 001-screenshot-15.13.22.png (masked 2)
        --- 15:14:27 screenshot emulator-5554 exit 1 mask_unproven
        002 15:16:00 logs emulator-5554 ok 002-logs-15.16.00.log (14 entries, redacted 3)
        003 15:17:00 batch step 4 emulator-5554 ok 003-screenshot-15.17.00.png
        004 unrecorded 004-screenshot-15.20.00.png
        3 files, 1 failure, 1 unrecorded
        """)
        let json = timeline.jsonLine(timeZone: RunFixture.timeZone)
        #expect(json.hasPrefix(#"{"version":1,"dir":"/tmp/run","label":"PR 123","startedAt":"2026-10-05T15:11:07.000+09:30","stoppedAt":"2026-10-05T15:42:50.000+09:30","entries":[{"n":1,"#))
        #expect(json.hasSuffix(#""files":3,"failures":1,"unrecorded":["004-screenshot-15.20.00.png"]}"#))
        _ = fixture
    }

    @Test("a numbered file no manifest line names is unrecorded")
    func orphans() throws {
        let fixture = try RunFixture()
        let folder = try RunFolder.prepare(fixture.folder()).folder
        for name in ["001-screenshot-15.11.07.png", "002-screenshot-15.11.09.png", "notes.txt"] {
            FileManager.default.createFile(atPath: folder.file(name), contents: Data())
        }
        try folder.append(RunManifestLine(n: 1, file: "001-screenshot-15.11.07.png", command: "screenshot", time: Date(), ms: 1, exit: 0))
        #expect(folder.unrecorded(given: folder.manifest()) == ["002-screenshot-15.11.09.png"])
    }

    @Test("run start and stop print the folder and the summary as JSON")
    func startAndStopCommands() async throws {
        let fixture = try RunFixture()
        let dir = fixture.folder()
        let started = try await TestHelpers.runOffsiderCommandSeparated("run start '\(dir)' --label 'PR 1' --mask-emails --json", environment: ["OFFSIDER_RUN": dir])
        #expect(started.exitCode == 0)
        #expect(started.stdout.contains(#""dir":"\#(dir)","label":"PR 1""#))
        #expect(started.stdout.contains(#""masks":{"secure":false,"emails":true,"ids":[]}"#))

        let stopped = try await TestHelpers.runOffsiderCommandSeparated("run stop --summary --json", environment: ["OFFSIDER_RUN": dir])
        #expect(stopped.stdout.hasPrefix(#"{"version":1,"dir":"\#(dir)","label":"PR 1""#))
        let none = try await TestHelpers.runOffsiderCommandSeparated("run stop")
        #expect(none.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "No run is active.")
        #expect(none.exitCode == 0)
    }
}

final class NumberBox: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Int] = []
    func append(_ value: Int) { lock.withLock { values.append(value) } }
    var sorted: [Int] { lock.withLock { values.sorted() } }
}

final class FixtureClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date(timeIntervalSince1970: 1_791_178_867)
    var now: Date {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}
