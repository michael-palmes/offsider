import Foundation

/// Where batch text goes; with `json`, stdout carries only NDJSON records and human text moves to stderr.
struct BatchOutput {
    let json: Bool
    let write: (String) -> Void
    let writeError: (String) -> Void

    static func console(json: Bool) -> BatchOutput {
        BatchOutput(
            json: json,
            write: { text in
                print(text, terminator: "")
                fflush(stdout)
            },
            writeError: { text in print(text, terminator: "", to: &standardError) }
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

    func report(_ result: BatchReadResult) {
        if let output = result.output, !json {
            write(output)
        }
        if let note = result.note {
            status(note)
        }
    }
}
