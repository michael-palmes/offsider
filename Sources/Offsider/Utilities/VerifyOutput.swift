import ArgumentParser
import Foundation
import OffsiderCore

/// `subject` starts the human lines; `target` goes in the JSON report.
struct VerifyRequest {
    let command: String
    let subject: String
    let target: String
    let backend: any DeviceBackend
    let device: DeviceID
    let options: VerificationOptions
    let styles: [TapDeliveryStyle?]
    /// The tree a selector was resolved on, so the verifier reads one tree fewer.
    var initialTree: UITree? = nil
    /// The element a selector resolved to: a LogBox toast may open the inspector, and a switch needs no baseline capture.
    var targetNode: UINode? = nil
    /// Sees the verifier's last read before the action, so a target that moved since it was resolved is acted on where it is now.
    var beforeAction: (UITree) async throws -> Void = { _ in }
}

/// Tracks how far a verified command got, so a failure under --json reports it.
@MainActor
final class VerifyProgress {
    /// Whether input may have reached the device, from every send since the command began.
    var dispatched: DispatchState { DispatchTracker.current.state }
    var attempts = 0
    var style: TapDeliveryStyle?
    /// When the command began, so the report's time and its resolve phase count from there.
    let startedAt: TimeInterval
    var phases = VerifyPhases()

    init(now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        startedAt = now
    }

    var elapsed: TimeInterval { ProcessInfo.processInfo.systemUptime - startedAt }
}

@MainActor
enum VerifyOutput {
    /// With --json, the screen check runs before the report is written, so its error carries any off or locked screen too.
    static func reportingFailures(
        command: String,
        target: String,
        options: VerificationOptions,
        scope: CommandScope = .current,
        write: (Data) -> Void = writeOutput,
        _ body: (VerifyProgress) async throws -> Void
    ) async throws {
        let progress = VerifyProgress()
        do {
            try await body(progress)
        } catch let exit as ExitCode {
            throw exit
        } catch {
            guard options.json else { throw error }
            let error = await scope.screenHint(for: error)
            let failed = VerifyReport(
                command: command,
                target: target,
                dispatched: progress.dispatched,
                verified: false,
                attempts: progress.attempts,
                change: .none,
                style: progress.style,
                elapsed: progress.elapsed,
                phases: progress.phases,
                error: ErrorReporter.payload(for: error, dispatched: progress.dispatched)
            )
            write(try failed.jsonData() + Data("\n".utf8))
            throw ReportedFailure(underlying: error, exitCode: failed.exitCode)
        }
    }

    static func perform(
        _ request: VerifyRequest,
        progress: VerifyProgress,
        action: (Verifier.Attempt, any InputSession) async throws -> Void
    ) async throws {
        let resolve = ProcessInfo.processInfo.systemUptime - progress.startedAt
        progress.phases.resolve = resolve
        Timings.record("resolve", seconds: resolve)
        let session = try await request.backend.openTrackedSession(for: request.device)
        var outcome: Verifier.Outcome
        do {
            outcome = try await Verifier.run(
                styles: request.styles,
                timeout: .milliseconds(Int((request.options.resolvedTimeout * 1000).rounded())),
                dependencies: .live(backend: request.backend, device: request.device),
                mode: request.options.mode,
                initialTree: request.initialTree,
                target: request.targetNode,
                beforeAction: request.beforeAction,
                onRetry: { failed, next in
                    writeError(retryLine(failed: failed, next: next))
                },
                action: { attempt in
                    progress.attempts = attempt.number
                    progress.style = attempt.style
                    try await action(attempt, session)
                }
            )
        } catch {
            await session.close()
            throw error
        }
        await session.close()
        outcome.phases.resolve = resolve
        progress.phases = outcome.phases
        try report(outcome, for: request, elapsed: progress.elapsed)
    }

    static func report(_ outcome: Verifier.Outcome, for request: VerifyRequest, elapsed: TimeInterval = 0) throws {
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
            dispatched: .yes,
            verified: outcome.verified,
            attempts: outcome.attempts,
            change: outcome.change,
            changes: outcome.changes,
            changesTruncated: outcome.changesTruncated,
            ignored: outcome.ignored,
            note: outcome.note,
            style: outcome.style,
            elapsed: elapsed,
            phases: outcome.phases
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
            let listed = changeList(outcome)
            change = "accessibility tree changed" + ((listed ?? outcome.summary).map { " (\($0))" } ?? "")
        case .screenshot:
            change = "screen changed"
        case .activity:
            change = "the launcher came to the front"
        case .element:
            change = outcome.summary ?? "element on screen"
        case .none:
            change = "no change"
        }
        let style = outcome.style.map { ", \($0.rawValue) style" } ?? ""
        let note = outcome.note == .keyboardClosed
            ? "; only the keyboard closed: the input may have been spent closing it; repeat it if the control shows no effect"
            : ""
        return "✓ \(request.subject) verified: \(change), attempt \(outcome.attempts) of \(max(request.styles.count, 1))\(style)\(note) "
            + outcome.phases.suffix(input: request.command)
    }

    static let listedChanges = 3

    /// Up to three changes, `value of text id=count "0" to "1"; button "Save" added`, and how many more; nil with none listed.
    static func changeList(_ outcome: Verifier.Outcome) -> String? {
        guard !outcome.changes.isEmpty else { return nil }
        let shown = outcome.changes.prefix(listedChanges).map { change -> String in
            switch change.kind {
            case .added: return "\(change.node) added"
            case .removed: return "\(change.node) removed"
            case .changed where change.field == "frame": return "\(change.node) moved"
            case .changed: return "\(change.field ?? "state") of \(change.node) \(quoted(change.old)) to \(quoted(change.new))"
            }
        }
        let more = outcome.changes.count - shown.count + outcome.changesTruncated
        return shown.joined(separator: "; ") + (more > 0 ? "; and \(more) more" : "")
    }

    private static func quoted(_ text: String?) -> String {
        text.map { "\"\($0)\"" } ?? "nothing"
    }

    /// `; ignored as live: price, volume` and the like, for a failure.
    static func ignoredText(_ ignored: [VerifyIgnored]) -> String {
        let groups: [(VerifyIgnored.Reason, String)] = [(.live, "live"), (.volatile, "already changing before the input"), (.toast, "LogBox toasts")]
        let parts = groups.compactMap { reason, name -> String? in
            let nodes = ignored.filter { $0.reason == reason }.map(\.node)
            guard !nodes.isEmpty else { return nil }
            return reason == .toast ? "a \(name) change" : "\(name): \(nodes.prefix(listedChanges).joined(separator: ", "))\(nodes.count > listedChanges ? " and \(nodes.count - listedChanges) more" : "")"
        }
        guard !parts.isEmpty else { return "" }
        return " Ignored \(parts.joined(separator: "; ")), which changed without the input\(ignored.contains { $0.reason == .live } ? "; not retried" : "")."
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
        if outcome.note == .logBoxOpened {
            return "✗ \(request.subject) was dispatched but the React Native LogBox inspector opened over the app, so its effect cannot be seen. Read the log, then close it with offsider rn logbox dismiss --device \(request.device.rawValue)."
        }
        if let id = request.options.verifyID {
            return "✗ \(request.subject) was dispatched but --verify-id '\(id)' did not come on screen within \(request.options.resolvedTimeout.formatted()) s after \(outcome.attempts) \(plural). Check the screen with describe-ui --summary."
        }
        return "✗ \(request.subject) was dispatched but nothing observable changed after \(outcome.attempts) \(plural)\(styleText).\(ignoredText(outcome.ignored)) "
            + (request.device.platform == .ios
                ? "Check the target with describe-ui, or run offsider doctor --device \(request.device.rawValue)."
                : "Check the target with describe-ui.")
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

    /// Rounded to 0.01, the precision of describe-ui frames.
    nonisolated private static func number(_ value: Double) -> String {
        let rounded = (value * 100).rounded() / 100
        return rounded.rounded() == rounded && abs(rounded) < 1e15 ? String(Int(rounded)) : String(rounded)
    }

    private static func writeOutput(_ data: Data) {
        FileHandle.standardOutput.write(data)
    }

    private static func writeError(_ line: String) {
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }
}
