import ArgumentParser
import Foundation
import OffsiderCore

/// What an input command learnt while it ran, for its `--json` line; written by one command step at a time.
final class InputDetails: @unchecked Sendable {
    var point: UIPoint?
    var percent: Double?
    var value: String?
    var holdMs: Int?
    var screenshots: [HeldScreenshot] = []
}

/// `--json` without `--verify`: one `InputReport` line on stdout, also on a failure, and the command's own lines on stderr.
@MainActor
enum InputOutput {
    static func reporting(
        command: String,
        target: String,
        json: Bool,
        console: Console = .current,
        scope: CommandScope = .current,
        _ body: @MainActor (InputDetails) async throws -> Void
    ) async throws {
        let details = InputDetails()
        guard json else { return try await body(details) }
        let startedAt = ProcessInfo.processInfo.systemUptime
        // The command's stdout, as an agent reads it, joins its notes on stderr.
        let lines = Console(out: .agent, err: console.err) { _, text in console.data(text, to: .err) }
        func report(_ error: ErrorPayload?) -> InputReport {
            InputReport(
                command: command, target: target, dispatched: DispatchTracker.current.state,
                point: details.point, percent: details.percent, value: details.value,
                holdMs: details.holdMs, screenshots: details.screenshots,
                elapsed: ProcessInfo.processInfo.systemUptime - startedAt, error: error
            )
        }
        do {
            try await Console.$current.withValue(lines) { try await body(details) }
        } catch let exit as ExitCode {
            throw exit
        } catch {
            let error = await scope.screenHint(for: error)
            let payload = ErrorReporter.payload(for: error, dispatched: DispatchTracker.current.state)
            let failed = report(payload.scrubbed { TerminalText.capped($0, cap: TerminalText.maxErrorCharacters) })
            console.data(failed.jsonLine() + "\n")
            throw ReportedFailure(underlying: error, exitCode: failed.exitCode)
        }
        console.data(report(nil).jsonLine() + "\n")
    }
}

/// `--json` for an input command without `VerificationOptions`, which carries its own.
struct InputJSONOption: ParsableArguments {
    @Flag(name: .customLong("json"), help: "Print one JSON result to stdout; human text goes to stderr.")
    var json = false
}
