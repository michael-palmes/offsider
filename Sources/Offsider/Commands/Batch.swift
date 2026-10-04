import ArgumentParser
import Foundation
import OffsiderCore

struct Batch: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Run ordered input and read steps using one device session.",
        discussion: """
        Batch runs a whole case (tap, wait, check, capture, read the tree) in one command. Steps run in order \
        and are written like the standalone commands without --device. Read steps run after the previous step's input is sent.

        Input steps:
          tap, swipe, gesture, touch, type, button, key, key-sequence, key-combo
          sleep <seconds>

        Read steps:
          wait, assert, screenshot, describe-ui

        Read steps print their usual output as they run; input steps print nothing to stdout, though warnings \
        such as an off-screen or covered tap still go to stderr. Steps cannot take --device, \
        --json, --verify, --verify-timeout or --retries. A step's own --wait-timeout or --poll-interval \
        overrides the batch-level value.

        With --json, stdout is NDJSON: one line per finished step, in this key order: step, kind, line, ok, ms; \
        a type step's line shows its text as <N characters>, never the text; \
        a failure adds exitCode and error; wait and assert add met, reason, match; screenshot adds its --json keys; \
        describe-ui adds tree (json format) or output (ndjson or text). A last line follows: \
        {"step":null,"kind":"batch","ok":...,"ms":...,"steps":...,"failed":...}, where steps counts every step \
        in the batch, run or not. Human text goes to stderr.

        Without --continue-on-error the first failure stops the batch. Exit codes: 1 when any step failed to run, \
        else 5 when a wait, assert or screenshot --compare condition was not met, else 0.

        Examples:
          offsider batch --device DEVICE_ID --json \\
            --step "tap --id open" --step "wait --id sheet-title" \\
            --step "assert --id state --has-value Open" \\
            --step "screenshot --output shot.png --scale points" \\
            --step "describe-ui --summary"
          offsider batch --device DEVICE_ID --json --file steps.txt
          cat steps.txt | offsider batch --device DEVICE_ID --stdin
        """
    )

    @OptionGroup
    var deviceOption: DeviceOption

    @Option(name: .customLong("step"), help: "Step to execute. Repeat for multiple steps.")
    var steps: [String] = []

    @Option(name: .customLong("file"), help: "Read steps from a file (one step per line).")
    var file: String?

    @Flag(name: .customLong("stdin"), help: "Read steps from stdin (one step per line).")
    var useStdin: Bool = false

    @Option(name: .customLong("ax-cache"), help: "Accessibility tree reuse for selector steps: perBatch reuses the latest read until a step sends input or sleeps; perStep reads fresh for every selector step; none is an alias of perStep.")
    var axCachePolicy: AXCachePolicy = .perBatch

    @Option(name: .customLong("type-submission"), help: "Type step submission mode.")
    var typeSubmissionMode: TypeSubmissionMode = .chunked

    @Option(name: .customLong("type-chunk-size"), help: "Maximum HID events per chunk when type-submission is chunked.")
    var typeChunkSize: Int = 200

    @Option(name: .customLong("tap-style"), help: "Default tap event style for tap steps: automatic uses physical touch for switches and a single tap event for other targets; simulator always sends a single tap event; physical uses touch down and up.")
    var tapStyle: TapStyle = .automatic

    @Flag(name: .customLong("continue-on-error"), help: "Continue executing later steps even if one step fails.")
    var continueOnError: Bool = false

    @Option(name: .customLong("wait-timeout"), help: "Maximum seconds to poll for selector-based elements before failing (0 = no waiting).")
    var waitTimeout: Double = 0

    @Option(name: .customLong("poll-interval"), help: "Seconds between accessibility tree polls when --wait-timeout is active.")
    var pollInterval: Double = 0.25

    @Flag(name: .customLong("mask-secure"), help: "Every screenshot step paints password fields black, reusing the cached tree when it is fresh. OFFSIDER_MASK_SECURE=1 turns this on by default.")
    var maskSecure = false

    @Flag(name: .customLong("no-settle"), help: "Tap steps act at once, without waiting out a transition an earlier input may have started.")
    var noSettle = false

    @Flag(name: .customLong("json"), help: "Print one NDJSON line per step to stdout, then a summary line; human text goes to stderr.")
    var json: Bool = false

    @Flag(name: .customLong("verbose"), help: "Enable verbose logging to stderr.")
    var verbose: Bool = false

    func validate() throws {
        let sourceCount = [!steps.isEmpty, file != nil, useStdin].filter { $0 }.count
        guard sourceCount == 1 else {
            throw ValidationError("Specify exactly one step source: --step, --file, or --stdin.")
        }

        guard typeChunkSize > 0 else {
            throw ValidationError("--type-chunk-size must be greater than 0.")
        }

        guard waitTimeout >= 0 else {
            throw ValidationError("--wait-timeout must be non-negative.")
        }

        if waitTimeout > 0 {
            guard pollInterval > 0 else {
                throw ValidationError("--poll-interval must be greater than 0 when --wait-timeout is active.")
            }
        }
    }

    func run() async throws {
        let logger = OffsiderLogger(writeToStdErr: verbose)
        let watchdog = DeviceWatchdog()
        let route = try await watchdog.guardingSetup(device: deviceOption.id) {
            try await DeviceRouter.routeForInput(deviceOption, logger: logger)
        }
        try await run(on: route, logger: logger, watchdog: watchdog)
    }

    /// Every step shares one input session, so an Android batch holds one gRPC client or adb executor throughout.
    func run(on route: DeviceRouter.Route, logger: OffsiderLogger, watchdog: DeviceWatchdog = DeviceWatchdog()) async throws {
        let backend = route.backend
        let device = route.device
        try await watchdog.guardingSetup(device: device.rawValue) { try await backend.prepare() }

        let stepLines = try loadStepLines()
        if stepLines.isEmpty {
            throw ValidationError("No executable steps found.")
        }
        for line in stepLines {
            if let tokens = try? ShellTokenizer.tokenize(line) {
                try BatchStepParser.rejectUnsupportedFlags(tokens)
            }
        }

        let record = noSettle ? nil : await TreeCache.load(for: device, backend: backend)
        let context = await MainActor.run {
            BatchContext(
                backend: backend,
                device: device,
                axCachePolicy: axCachePolicy,
                typeSubmissionMode: typeSubmissionMode,
                typeChunkSize: typeChunkSize,
                tapStyle: tapStyle,
                waitTimeout: waitTimeout,
                pollInterval: pollInterval,
                watchdog: watchdog,
                maskSecure: maskSecure,
                noSettle: noSettle,
                cachedRecord: record
            )
        }

        let session = try await watchdog.guardingSetup(device: device.rawValue) { try await backend.openInputSession(for: device) }
        let output = BatchOutput.console(json: json)

        do {
            try await Self.runSteps(
                stepLines,
                context: context,
                session: session,
                continueOnError: continueOnError,
                output: output,
                logger: logger
            )
        } catch {
            await session.close()
            throw error
        }
        await session.close()

        output.status("✓ Batch completed successfully (\(stepLines.count) steps)")
    }

    /// Runs every step (or up to the first failure), reporting each through `output`; throws exit 1 or 5 as the help describes.
    @MainActor
    @discardableResult
    static func runSteps(
        _ stepLines: [String],
        context: BatchContext,
        session: any InputSession,
        continueOnError: Bool,
        output: BatchOutput = .console(json: false),
        logger: OffsiderLogger
    ) async throws -> [BatchStepRecord] {
        let runner = BatchPlanRunner(session: TrackedInputSession.wrapping(session), logger: logger)
        let clock = ContinuousClock()
        let batchStart = clock.now
        var records: [BatchStepRecord] = []

        for (index, line) in stepLines.enumerated() {
            let record = await runStep(index + 1, line: line, context: context, runner: runner, output: output, logger: logger)
            records.append(record)
            if output.json {
                output.write(record.jsonLine() + "\n")
            }
            if !record.ok && !continueOnError {
                break
            }
        }

        let failed = records.filter { !$0.ok }
        if output.json {
            let elapsed = Self.seconds(clock.now - batchStart)
            output.write(BatchStepRecord.summaryLine(ok: failed.isEmpty, elapsed: elapsed, steps: stepLines.count, failed: failed.count) + "\n")
        }
        try finish(failed, continueOnError: continueOnError, output: output)
        return records
    }

    @MainActor
    private static func runStep(
        _ number: Int,
        line: String,
        context: BatchContext,
        runner: BatchPlanRunner,
        output: BatchOutput,
        logger: OffsiderLogger
    ) async -> BatchStepRecord {
        let clock = ContinuousClock()
        let start = clock.now
        var stepName = "<unparsed>"
        var detail = BatchStepRecord.Detail.none
        var failure: BatchStepRecord.Failure?
        var parsedTokens: [String]?
        var sendsInput = true
        DispatchTracker.current.reset()
        do {
            let tokens = try ShellTokenizer.tokenize(line)
            parsedTokens = tokens
            stepName = tokens.first ?? "<empty>"
            // Also after a failure: a step can send input before it fails.
            defer {
                if let kind = BatchStepKind(rawValue: stepName), kind.mayChangeScreen {
                    context.invalidateTree(sentInput: kind != .sleep)
                }
            }
            switch try await BatchStepParser.parseStep(tokens, deviceID: context.device.rawValue, context: context, logger: logger) {
            case .input(let primitives):
                try await runner.run(BatchPlan(primitives: primitives))
            case .read(let step):
                sendsInput = false
                let result = try await step.runInBatch(context: context, logger: logger)
                detail = result.detail
                output.report(result)
                if let unmet = result.unmet {
                    failure = .init(error: ErrorPayload(reason: .conditionNotMet, message: unmet))
                }
            }
        } catch {
            var payload = ErrorReporter.payload(for: error, dispatched: sendsInput ? DispatchTracker.current.state : nil)
            if BatchStepRedaction.isTypeLine(line) {
                let secrets = [line] + BatchStepRedaction.textTokens(parsedTokens ?? [])
                payload = payload.scrubbed { BatchStepRedaction.scrub($0, removing: secrets) }
            }
            failure = .init(error: payload)
        }
        return BatchStepRecord(
            step: number, kind: stepName, line: BatchStepRedaction.redactedLine(line, tokens: parsedTokens), elapsed: seconds(clock.now - start), failure: failure, detail: detail
        )
    }

    /// The code of the first step that failed to run; else exit 5 when only conditions were not met.
    @MainActor
    private static func finish(_ failed: [BatchStepRecord], continueOnError: Bool, output: BatchOutput) throws {
        let failures = failed.compactMap { record in record.failure.map { (record, $0) } }
        guard !failures.isEmpty else { return }

        let text: String
        if continueOnError {
            let lines = failures.map { "Step \($0.0.step) failed: [\($0.0.kind)] -> \($0.1.message)" }
            text = "Batch completed with \(failures.count) failure(s):\n" + lines.joined(separator: "\n")
        } else {
            let (record, failure) = failures[0]
            text = "Step \(record.step) failed: [\(record.kind)]\n\(failure.message)"
        }

        if failures.allSatisfy({ $0.1.isConditionNotMet }) {
            output.writeError(text + "\n")
            throw ExitCode(OffsiderExitCode.unverified.rawValue)
        }
        let code = failures.first { !$0.1.isConditionNotMet }?.1.error.exitCode ?? .failure
        throw ReportedFailure(underlying: CLIError(errorDescription: text), exitCode: code)
    }

    private static func seconds(_ duration: Duration) -> TimeInterval {
        let components = duration.components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }

    private func loadStepLines() throws -> [String] {
        let rawLines: [String]
        if !steps.isEmpty {
            rawLines = steps
        } else if let file {
            let contents: String
            do {
                contents = try String(contentsOfFile: file, encoding: .utf8)
            } catch {
                throw ValidationError("Failed to read step file '\(file)': \(error.localizedDescription)")
            }
            rawLines = contents.components(separatedBy: .newlines)
        } else {
            rawLines = readStdinLines()
        }

        return rawLines
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    private func readStdinLines() -> [String] {
        var lines: [String] = []
        while let line = readLine() {
            lines.append(line)
        }
        return lines
    }
}

