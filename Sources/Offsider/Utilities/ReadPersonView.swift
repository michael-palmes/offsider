import Foundation
import OffsiderCore

/// What the read commands and batch show a person; an agent's lines are built where they always were and pass through unchanged.
enum ReadPersonView {
    /// A log read's `Warning: …`, `Note: …` or plain line as a person's warning or note.
    static func logNotice(_ line: String) -> Notice {
        let warning = "Warning: "
        let note = "Note: "
        if line.hasPrefix(warning) { return .warning(sentence(String(line.dropFirst(warning.count)))) }
        return .note(sentence(line.hasPrefix(note) ? String(line.dropFirst(note.count)) : line))
    }

    /// A file a capture wrote: an agent's stderr line; a person's receipt or batch row says it, or `person` when stdout goes elsewhere.
    static func saved(_ agent: String, person: String, console: Console = .current) {
        if console.err.profile == .agent {
            console.data(agent + "\n", to: .err)
        } else if console.out.profile == .agent {
            console.notice(.note(person, mark: .screenshot))
        }
    }

    // MARK: Screenshot

    /// `✅  Screenshot saved` with the path and size for a person; the bare path for an agent.
    static func screenshot(_ report: ScreenshotReport, path: String, home: String = NSHomeDirectory()) -> Page {
        var size = "\(report.width) x \(report.height) px"
        if let masked = report.masked, masked > 0 { size += " · \(masked) masked" }
        return Page([.person([.outcome(.done("Screenshot saved", details: [TerminalText.homePath(path, home: home), size]))]), .agent(path + "\n")])
    }

    /// A compare's verdict for a person, ✅ when it met `--expect` and ❌ when not; the summary line for an agent.
    static func comparison(_ report: ScreenshotReport, _ result: ScreenCompare.Result, home: String = NSHomeDirectory()) -> Page {
        let headline: String
        switch (result.outcome, result.met) {
        case (.changed, true): headline = "Changed from the baseline"
        case (.unchanged, true): headline = "Matches the baseline"
        case (.changed, false): headline = "Differs from the baseline"
        case (.unchanged, false): headline = "No change from the baseline"
        }
        var details = [counts(result)]
        if let diff = report.diffPath { details.append("Diff at \(TerminalText.homePath(diff, home: home))") }
        if let path = report.path { details.append("Saved to \(TerminalText.homePath(path, home: home))") }
        return Page([.person([.outcome(Outcome(ok: result.met, headline: headline, details: details))]), .agent(result.summary + "\n")])
    }

    /// `37 of 512 tiles changed (7.2%) · 1830 pixels`, saying when the change was within the threshold.
    static func counts(_ result: ScreenCompare.Result) -> String {
        var text = "\(result.changedTiles) of \(result.comparedTiles) tiles changed"
        if result.changedTiles > 0 { text += String(format: " (%.1f%%)", result.changedFraction * 100) }
        if let pixels = result.pixels { text += " · \(pixels.changedPixels) \(pixels.changedPixels == 1 ? "pixel" : "pixels")" }
        if result.outcome == .unchanged, result.changedTiles > 0 { text += " · within the threshold" }
        return text
    }

    // MARK: Batch

    /// A step line as a person reads it: no typed text and no count of its characters.
    static func stepLine(_ line: String) -> String {
        line.replacing(#/<\d+ characters?>/#, with: "<hidden>")
    }

    /// The step's line before it runs, redacted as its record will be, for the spinner and a step that never ran.
    static func plannedLine(_ line: String) -> String {
        stepLine(BatchStepRedaction.redactedLine(line, tokens: try? ShellTokenizer.tokenize(line)))
    }

    /// `120 ms` under a second, else `1.2 s`.
    static func elapsed(_ seconds: TimeInterval) -> String {
        seconds < 0.95 ? "\(max(0, Int((seconds * 1000).rounded()))) ms" : WaitLoop.seconds(seconds)
    }

    /// The dim words after a step: why it failed, a capture's file or verdict, which `--any` selector matched, else how long it took.
    static func stepDetail(_ record: BatchStepRecord, note: String?, home: String = NSHomeDirectory()) -> String {
        if let failure = record.failure {
            return failure.message.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? ""
        }
        var parts: [String] = []
        switch record.detail {
        case .screenshot(let report):
            if let comparison = report.comparison {
                parts.append(counts(comparison))
                if let diff = report.diffPath { parts.append("diff \(TerminalText.homePath(diff, home: home))") }
            } else if let path = report.path {
                parts.append(TerminalText.homePath(path, home: home))
            }
        case .wait(let outcome):
            if let matched = outcome.matched { parts.append("--\(matched.by) '\(matched.text)'") }
            if note?.hasSuffix(" (\(Wait.redactedNote))") == true { parts.append("matched on the real text") }
        case .none, .describe:
            break
        }
        return (parts + [elapsed(record.elapsed)]).joined(separator: " · ")
    }

    /// `  ✓ 2  wait --id home  1.2 s`, cut to the canvas: a detail with no room drops under the line, or is left out for a skipped step.
    static func stepRow(number: Int, of total: Int, line: String, status: RowStatus, detail: String, canvas: Canvas) -> String {
        let style = canvas.style
        let digits = String(max(total, number)).count
        let place = String(repeating: " ", count: digits - String(number).count) + String(number)
        let lead = "  " + style.status(status) + " " + place + "  "
        let leadWidth = 4 + digits + 2
        let room = max(canvas.usable - leadWidth, 1)
        let text = TerminalText.line(line, cap: TerminalText.maxErrorCharacters, keepsTab: false)
        let detail = TerminalText.line(detail, cap: TerminalText.maxErrorCharacters, keepsTab: false)
        let tone: (String) -> String = status == .skip ? style.dim : { $0 }
        func cut(_ text: String, _ width: Int) -> String { TerminalText.truncate(text, to: max(width, 1), ellipsis: style.ellipsis) }
        let textWidth = TerminalText.width(text)
        guard !detail.isEmpty else { return lead + tone(cut(text, room)) + "\n" }
        if textWidth + 2 + TerminalText.width(detail) <= room {
            return lead + tone(text) + "  " + style.dim(detail) + "\n"
        }
        if status == .skip { return lead + tone(cut(text, room)) + "\n" }
        if textWidth + 2 + minimumDetail <= room {
            return lead + tone(text) + "  " + style.dim(cut(detail, room - textWidth - 2)) + "\n"
        }
        let indent = String(repeating: " ", count: leadWidth)
        return lead + tone(cut(text, room)) + "\n" + indent + style.dim(cut(detail, room)) + "\n"
    }

    /// Fewer columns than this left beside a step's line move its detail onto a row of its own.
    static let minimumDetail = 16

    /// The closing: ✅ with the count and time, or ❌ naming the step that stopped the batch, the one that failed, or how many did.
    static func batchClosing(steps: Int, failed: [Int], ran: Int, elapsed: TimeInterval) -> Outcome {
        let time = self.elapsed(elapsed)
        let count = steps == 1 ? "1 step" : "\(steps) steps"
        guard let first = failed.first else { return .done("Batch done", details: ["\(count) · \(time)"]) }
        let details = ["\(ran - failed.count) of \(count) passed · \(time)"]
        if ran < steps { return .failed("Batch stopped at step \(first)", details: details) }
        return .failed(failed.count == 1 ? "Step \(first) failed" : "\(failed.count) of \(count) failed", details: details)
    }

    /// The warning a person reads when a batch failed after a step may have sent input.
    static let dispatched = Notice.warning("Input may have reached the device; check before resending")

    /// A capital for a lower-case first word, never for a name such as `emulator-5554`.
    private static func sentence(_ text: String) -> String {
        let word = text.prefix { $0 != " " }
        guard let first = word.first, word.allSatisfy({ $0.isLetter && $0.isLowercase }) else { return text }
        return first.uppercased() + text.dropFirst()
    }
}
