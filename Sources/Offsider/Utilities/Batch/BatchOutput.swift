import Foundation
import OffsiderCore

/// Where batch text goes; with `json`, stdout carries only NDJSON records and human text moves to stderr.
struct BatchOutput {
    let json: Bool
    let write: (String) -> Void
    let writeError: (String) -> Void
    /// The console of a person reading stdout, who sees a row per step and a closing instead of the status lines; nil for an agent or `--json`.
    var person: Console? = nil

    static func console(json: Bool, console: Console = .current) -> BatchOutput {
        BatchOutput(
            json: json,
            write: { console.data($0) },
            writeError: { console.data($0, to: .err) },
            person: !json && console.out.profile == .person ? console : nil
        )
    }

    /// A human status line.
    func status(_ line: String) {
        if json {
            writeError(line + "\n")
        } else {
            write(line + "\n")
        }
    }

    /// A read step's output and note; a person's row carries them instead.
    func report(_ result: BatchReadResult) {
        guard person == nil else { return }
        if let output = result.output, !json {
            write(output)
        }
        if let note = result.note {
            status(note)
        }
    }

    /// A person's header before the first step, a blank line under it as a page has.
    func begin(steps: Int) {
        guard let person else { return }
        person.show(Page([.person([.header(Header(.steps, "Batch", [steps == 1 ? "1 step" : "\(steps) steps"]))])]))
        person.data("\n")
    }

    /// A person's row for a step that ended, then any tree it read, as it is.
    func finished(_ record: BatchStepRecord, result: BatchReadResult?, of total: Int) {
        guard let person else { return }
        let status: RowStatus = record.ok ? .ok : .fail
        let row = ReadPersonView.stepRow(
            number: record.step, of: total, line: ReadPersonView.stepLine(record.line), status: status,
            detail: ReadPersonView.stepDetail(record, note: result?.note), canvas: person.out.canvas
        )
        person.data(row)
        if case .describe = record.detail, let output = result?.output { person.data(output) }
    }

    /// A person's dimmed rows for the steps a failure stopped the batch before.
    func notRun(_ lines: ArraySlice<String>, of total: Int) {
        guard let person else { return }
        for (number, line) in zip(lines.indices, lines) {
            person.data(ReadPersonView.stepRow(
                number: number + 1, of: total, line: ReadPersonView.plannedLine(line), status: .skip, detail: "not run", canvas: person.out.canvas
            ))
        }
    }

    /// The end of a batch whose steps all ran: a person's ✅, else the agent's status line.
    func completed(steps: Int, elapsed: TimeInterval) {
        guard let person else {
            status("✓ Batch completed successfully (\(steps) steps)")
            return
        }
        person.data("\n")
        person.show(Page([.person([.outcome(ReadPersonView.batchClosing(steps: steps, failed: [], ran: steps, elapsed: elapsed))])]))
    }

    /// Failed steps that only missed their condition: a person's ❌ and a warning when input may have gone; the agent's `summary` on an agent's stderr.
    func unmet(_ summary: String, steps: Int, failed: [Int], ran: Int, dispatched: DispatchState, elapsed: TimeInterval) {
        guard let person else {
            writeError(summary + "\n")
            return
        }
        person.data("\n")
        person.show(Page([.person([.outcome(ReadPersonView.batchClosing(steps: steps, failed: failed, ran: ran, elapsed: elapsed))])]))
        if person.err.profile == .agent {
            writeError(summary + "\n")
        } else if dispatched != .no {
            person.notice(ReadPersonView.dispatched)
        }
    }
}
