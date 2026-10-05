import ArgumentParser
import Darwin
import Foundation
import OffsiderCore

/// A command with `--json`; when it is set, a failure without a report of its own prints one error envelope on stdout.
protocol JSONReportingCommand {
    var wantsJSON: Bool { get }
}

/// A failure whose JSON report the command already printed; only the stderr line and the exit code remain.
struct ReportedFailure: UserFacingError {
    let underlying: any Error
    let exitCode: OffsiderExitCode

    var userFacingDescription: String { OffsiderCommand.message(for: underlying) }
}

/// Turns every failure into its exit code, the `Error:` line on stderr and, under `--json`, one envelope on stdout.
enum ErrorReporter {
    struct Context: Sendable {
        var command: String?
        var wantsJSON: Bool
        var device: String?
    }

    /// Set once on the main thread before the command runs; the watchdog reads it from its own queue.
    nonisolated(unsafe) static var context = Context(command: nil, wantsJSON: false, device: nil)

    static func prepare(command: (any ParsableCommand)?, arguments: [String]) {
        let name = command.map { CommandPath.of($0) } ?? arguments.first { !$0.hasPrefix("-") }
        let wantsJSON = (command as? any JSONReportingCommand)?.wantsJSON ?? arguments.contains("--json")
        context = Context(command: name, wantsJSON: wantsJSON, device: deviceArgument(in: arguments))
    }

    /// The JSON `error` object for `error`; `<DEVICE_ID>` in a hint becomes the `--device` value.
    static func payload(for error: any Error, dispatched: DispatchState? = nil) -> ErrorPayload {
        let error = (error as? ReportedFailure)?.underlying ?? error
        let payload: ErrorPayload
        if let failure = error as? any OffsiderFailure {
            payload = ErrorPayload(failure, dispatched: dispatched)
        } else if OffsiderCommand.exitCode(for: error) == .validationFailure {
            payload = ErrorPayload(reason: .usage, message: OffsiderCommand.message(for: error), dispatched: dispatched)
        } else {
            payload = ErrorPayload(reason: .commandFailed, message: OffsiderCommand.message(for: error), dispatched: dispatched)
        }
        guard let device = context.device, let hint = payload.hint, hint.contains("<DEVICE_ID>") else { return payload }
        return ErrorPayload(
            reason: payload.reason,
            message: payload.message,
            hint: hint.replacingOccurrences(of: "<DEVICE_ID>", with: device),
            dispatched: payload.dispatched,
            candidates: payload.candidates
        )
    }

    static func exit(_ error: any Error) -> Never {
        if let reported = error as? ReportedFailure {
            writeErrorLine(OffsiderCommand.message(for: reported.underlying))
            Darwin.exit(reported.exitCode.rawValue)
        }
        if error is ExitCode || OffsiderCommand.exitCode(for: error) == .success {
            OffsiderCommand.exit(withError: error)
        }
        if let failure = error as? any OffsiderFailure {
            writeEnvelopeIfWanted(payload(for: error))
            writeErrorLine(OffsiderCommand.message(for: error))
            Darwin.exit(failure.exitCode.rawValue)
        }
        let payload = payload(for: error)
        // When `--json` itself is the mistake, the command never promised JSON.
        if payload.reason != .usage || !payload.message.contains("--json") {
            writeEnvelopeIfWanted(payload)
        }
        OffsiderCommand.exit(withError: error)
    }

    /// The watchdog's exit: the device stopped answering, so the process ends from another thread.
    @Sendable static func exitUnresponsive(_ line: String) {
        let message = line.hasPrefix("Error: ") ? String(line.dropFirst("Error: ".count)) : line
        writeEnvelopeIfWanted(ErrorPayload(reason: .deviceUnresponsive, message: message, hint: context.device.map { "offsider doctor --device \($0)" }))
        writeErrorLine(message)
        Darwin.exit(FailureReason.deviceUnresponsive.exitCode.rawValue)
    }

    static func writeEnvelopeIfWanted(_ payload: ErrorPayload) {
        guard context.wantsJSON else { return }
        let line = ErrorEnvelope(command: context.command, error: payload).jsonLine() + "\n"
        FileHandle.standardOutput.write(Data(line.utf8))
    }

    private static func writeErrorLine(_ message: String) {
        FileHandle.standardError.write(Data("Error: \(message)\n".utf8))
    }

    static func deviceArgument(in arguments: [String]) -> String? {
        for (index, argument) in arguments.enumerated() {
            if argument == "--device", index + 1 < arguments.count { return arguments[index + 1] }
            if argument.hasPrefix("--device=") { return String(argument.dropFirst("--device=".count)) }
        }
        return nil
    }
}
