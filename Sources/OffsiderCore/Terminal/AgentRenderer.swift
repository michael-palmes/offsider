import Foundation

/// A page for an agent or a script: only the information, one line per item, no escapes and no width, so nothing wraps.
public enum AgentRenderer {
    public static func body(_ blocks: [Block]) -> String {
        blocks.map(block).joined()
    }

    /// A header row of agent titles, then rows padded by characters; a missing cell prints `-`, untrusted cells are quoted.
    public static func table(_ table: Table, profile: OutputProfile = .agent) -> String {
        let shown = table.columns.indices.filter { table.columns[$0].agent != nil }
        let header = shown.map { table.columns[$0].agent ?? "" }
        let rows: [[String]] = [header] + table.rows.map { row in
            shown.map { column -> String in
                guard column < row.cells.count, let cell = row.cells[column] else { return "-" }
                let text = cell.untrusted
                    ? TerminalText.field(cell.text, cap: table.agentCap, profile: profile)
                    : TerminalText.line(cell.text, cap: table.agentCap)
                return cell.tag.map { text + " (\($0))" } ?? text
            }
        }
        let widths = header.indices.map { column in rows.map { $0[column].count }.max() ?? 0 }
        return rows.map { row in
            row.enumerated().map { column, cell in
                column == row.count - 1 ? cell : cell + String(repeating: " ", count: widths[column] - cell.count)
            }
            .joined(separator: "  ")
        }
        .joined(separator: "\n") + "\n"
    }

    /// `Warning: ` or `Note: ` and the sentence, then `Try: ` unless it names the command; a next step is a person's only.
    public static func notices(_ notices: [Notice]) -> String {
        notices.map(notice).joined()
    }

    public static func notice(_ notice: Notice) -> String {
        let prefix: String
        switch notice.kind {
        case .warning: prefix = "Warning: "
        case .note: prefix = "Note: "
        case .next: return ""
        }
        let sentence = notice.agentText ?? notice.text
        var text = prefix + line(sentence) + "\n"
        if let command = notice.command, !command.isEmpty, !sentence.contains(command) {
            text += "Try: " + line(command) + "\n"
        }
        return text
    }

    private static func block(_ block: Block) -> String {
        switch block {
        case .header, .person:
            return ""
        case .table(let table):
            return self.table(table)
        case .fields(let fields):
            return fields.map { field in
                let value = field.value.untrusted ? TerminalText.field(field.value.text, profile: .agent) : line(field.value.text)
                return line(field.label) + ": " + value + (field.value.tag.map { " (\($0))" } ?? "") + "\n"
            }.joined()
        case .prose(let text):
            return line(text) + "\n"
        case .outcome(let outcome):
            return ([outcome.headline] + outcome.details).map { line($0) + "\n" }.joined()
        case .commands(let title, let shortcuts):
            let commands = shortcuts.map { line($0.command) }
            let widest = commands.map(\.count).max() ?? 0
            let rows = zip(commands, shortcuts).map { command, shortcut in
                "  " + command + String(repeating: " ", count: widest - command.count) + "  " + line(shortcut.about) + "\n"
            }
            return (title.map { line($0) + "\n" } ?? "") + rows.joined()
        case .agent(let text):
            return text
        }
    }

    private static func line(_ text: String) -> String {
        TerminalText.line(text, cap: TerminalText.maxErrorCharacters, keepsTab: false)
    }
}
