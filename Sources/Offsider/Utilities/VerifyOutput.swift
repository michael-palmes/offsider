import ArgumentParser
import Foundation
import OffsiderCore

/// `subject` starts the human lines; `target` goes in the JSON report.
struct VerifyRequest {
    let command: String
    let subject: String
    let target: String
    let simulatorUDID: String
    let options: VerificationOptions
    let styles: [TapDeliveryStyle?]
}

/// Tracks how far a verified command got, so a failure under --json reports it.
@MainActor
final class VerifyProgress {
    var dispatched = false
    var attempts = 0
    var style: TapDeliveryStyle?
}

@MainActor
enum VerifyOutput {
    static func reportingFailures(
        command: String,
        target: String,
        options: VerificationOptions,
        _ body: (VerifyProgress) async throws -> Void
    ) async throws {
        let progress = VerifyProgress()
        do {
            try await body(progress)
        } catch let exit as ExitCode {
            throw exit
        } catch {
            if options.json {
                let failed = VerifyReport(
                    command: command,
                    target: target,
                    dispatched: progress.dispatched,
                    verified: false,
                    attempts: progress.attempts,
                    change: .none,
                    style: progress.style,
                    error: message(for: error)
                )
                writeOutput(try failed.jsonData() + Data("\n".utf8))
            }
            throw error
        }
    }

    static func perform(
        _ request: VerifyRequest,
        progress: VerifyProgress,
        logger: OffsiderLogger,
        action: (Verifier.Attempt, HIDInteractor.Session) async throws -> Void
    ) async throws {
        let session = try await HIDInteractor.makeSession(for: request.simulatorUDID, logger: logger)
        let outcome: Verifier.Outcome
        do {
            outcome = try await Verifier.run(
                styles: request.styles,
                timeout: .milliseconds(Int((request.options.resolvedTimeout * 1000).rounded())),
                dependencies: .live(session: session, logger: logger),
                onRetry: { failed, next in
                    writeError(retryLine(failed: failed, next: next))
                },
                action: { attempt in
                    progress.attempts = attempt.number
                    progress.style = attempt.style
                    try await action(attempt, session)
                    progress.dispatched = true
                }
            )
        } catch {
            await HIDInteractor.closeSession(session)
            throw error
        }
        await HIDInteractor.closeSession(session)
        try report(outcome, for: request)
    }

    static func report(_ outcome: Verifier.Outcome, for request: VerifyRequest) throws {
        let json = request.options.json
        if outcome.verified {
            let line = verifiedLine(outcome, for: request)
            if json { writeError(line) } else { writeOutput(Data((line + "\n").utf8)) }
        } else {
            writeError(unverifiedLine(outcome, for: request))
        }
        let result = VerifyReport(
            command: request.command,
            target: request.target,
            dispatched: true,
            verified: outcome.verified,
            attempts: outcome.attempts,
            change: outcome.change,
            style: outcome.style
        )
        if json {
            writeOutput(try result.jsonData() + Data("\n".utf8))
        }
        if result.exitCode != .success {
            throw ExitCode(result.exitCode.rawValue)
        }
    }

    static func verifiedLine(_ outcome: Verifier.Outcome, for request: VerifyRequest) -> String {
        let change: String
        switch outcome.change {
        case .accessibilityTree:
            change = "accessibility tree changed" + (outcome.summary.map { " (\($0))" } ?? "")
        case .screenshot:
            change = "screen changed"
        case .none:
            change = "no change"
        }
        let style = outcome.style.map { ", \($0.rawValue) style" } ?? ""
        return "✓ \(request.subject) verified: \(change), attempt \(outcome.attempts) of \(max(request.styles.count, 1))\(style)"
    }

    static func unverifiedLine(_ outcome: Verifier.Outcome, for request: VerifyRequest) -> String {
        let plural = outcome.attempts == 1 ? "attempt" : "attempts"
        let styles = request.styles.prefix(outcome.attempts).compactMap { $0?.rawValue }
        let styleText: String
        if styles.count > 1 {
            styleText = " (\(styles.dropLast().joined(separator: ", ")), then \(styles.last!) style)"
        } else if let only = styles.first {
            styleText = " (\(only) style)"
        } else {
            styleText = ""
        }
        return "✗ \(request.subject) was dispatched but nothing observable changed after \(outcome.attempts) \(plural)\(styleText). "
            + "Check the target with describe-ui, or run offsider doctor --udid \(request.simulatorUDID)."
    }

    static func retryLine(failed: Verifier.Attempt, next: Verifier.Attempt) -> String {
        if let failedStyle = failed.style, let nextStyle = next.style {
            return "! No observable change after attempt \(failed.number) (\(failedStyle.rawValue) style); retrying with \(nextStyle.rawValue) style"
        }
        return "! No observable change after attempt \(failed.number); retrying"
    }

    nonisolated static func pointDescription(x: Double, y: Double) -> String {
        "(\(number(x)), \(number(y)))"
    }

    nonisolated private static func number(_ value: Double) -> String {
        value.rounded() == value && abs(value) < 1e15 ? String(Int(value)) : String(value)
    }

    private static func message(for error: Error) -> String {
        if let error = error as? UserFacingError { return error.userFacingDescription }
        if let error = error as? LocalizedError, let description = error.errorDescription { return description }
        return String(describing: error)
    }

    private static func writeOutput(_ data: Data) {
        FileHandle.standardOutput.write(data)
    }

    private static func writeError(_ line: String) {
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }
}
