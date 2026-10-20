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
        context = Context(command: name, wantsJSON: wantsJSON, device: deviceArgument(in: arguments) ?? DeviceDefault.resolve(explicit: nil)?.id)
        ErrorAudience.configure(jsonOutput: wantsJSON)
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
        return payload.replacingHint(hint.replacingOccurrences(of: "<DEVICE_ID>", with: device))
    }

    /// The exit code and reason a failure ends with, for an evidence run's manifest.
    static func status(for error: any Error) -> (exit: Int32, reason: String?) {
        if let reported = error as? ReportedFailure {
            return (reported.exitCode.rawValue, payload(for: reported.underlying).reason.rawValue)
        }
        if let code = error as? ExitCode {
            return (code.rawValue, code.rawValue == OffsiderExitCode.unverified.rawValue ? FailureReason.conditionNotMet.rawValue : nil)
        }
        if let failure = error as? any OffsiderFailure {
            return (failure.exitCode.rawValue, failure.reason.rawValue)
        }
        let code = OffsiderCommand.exitCode(for: error).rawValue
        return (code, payload(for: error).reason.rawValue)
    }

    static func exit(_ error: any Error) -> Never {
        if let reported = error as? ReportedFailure {
            writeErrorLine(OffsiderCommand.message(for: reported.underlying), hint: payload(for: reported.underlying).hint)
            Darwin.exit(reported.exitCode.rawValue)
        }
        if error is ExitCode || OffsiderCommand.exitCode(for: error) == .success {
            OffsiderCommand.exit(withError: error)
        }
        if let failure = error as? any OffsiderFailure {
            let payload = payload(for: error)
            writeEnvelopeIfWanted(payload)
            writeErrorLine(OffsiderCommand.message(for: error), hint: payload.hint)
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
        exitFromTimer(reason: .deviceUnresponsive, message: message, hint: context.device.map { "offsider doctor --device \($0)" })
    }

    /// Reports and exits from a timer, while the main actor is blocked and cannot throw.
    @Sendable static func exitFromTimer(reason: FailureReason, message: String, hint: String?) {
        writeEnvelopeIfWanted(ErrorPayload(reason: reason, message: message, hint: hint))
        writeErrorLine(message, hint: hint)
        Darwin.exit(reason.exitCode.rawValue)
    }

    static func writeEnvelopeIfWanted(_ payload: ErrorPayload) {
        guard context.wantsJSON else { return }
        let capped = payload.scrubbed { TerminalText.capped($0, cap: TerminalText.maxErrorCharacters) }
        Console.current.data(envelopeLine(capped, command: context.command) + "\n")
    }

    /// The envelope with its `untrusted` list: a message can quote device text, and candidates, covers and saved users always do.
    static func envelopeLine(_ payload: ErrorPayload, command: String?) -> String {
        UntrustedPaths.appending(payload.untrustedPaths(), to: ErrorEnvelope(command: command, error: payload).jsonLine())
    }

    /// A person sees the cause in bold red and a `Try` line; an agent the plain `Error:` and `Try:` lines.
    static func writeErrorLine(_ message: String, hint: String? = nil) {
        Console.current.release()
        let text = ErrorAudience.current == .person
            ? PersonRenderer.error(message, hint: hint, canvas: Console.current.err.canvas)
            : errorText(message) + (context.wantsJSON ? "" : hintText(hint, message: message, style: .plain))
        Console.current.data(text, to: .err)
    }

    /// `Error: <message>` and a newline, with control and bidi characters escaped, continuation lines indented and at most 4 KiB shown.
    static func errorText(_ message: String) -> String {
        "Error: \(TerminalText.block(TerminalText.capped(message, cap: TerminalText.maxErrorCharacters)))\n"
    }

    /// `Try: <hint>` and a newline, dim on a terminal; empty when there is no hint or the message already names it.
    static func hintText(_ hint: String?, message: String, style: TerminalStyle) -> String {
        guard let hint, !hint.isEmpty, !message.contains(hint) else { return "" }
        let line = "Try: \(TerminalText.line(hint, cap: TerminalText.maxErrorCharacters, keepsTab: false))"
        return (style.colours ? style.dim(line) : line) + "\n"
    }

    static func deviceArgument(in arguments: [String]) -> String? {
        for (index, argument) in arguments.enumerated() {
            if argument == "--device", index + 1 < arguments.count { return arguments[index + 1] }
            if argument.hasPrefix("--device=") { return String(argument.dropFirst("--device=".count)) }
        }
        return nil
    }
}
