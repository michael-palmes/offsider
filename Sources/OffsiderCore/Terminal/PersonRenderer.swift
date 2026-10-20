import Foundation

/// A page for a person: a header with its summary, rows behind status dots and notices with commands, fitted to the canvas.
public enum PersonRenderer {
    /// The most notices of one kind a person sees before `…and N more`.
    public static let noticesPerKind = 5

    public static func body(_ blocks: [Block], canvas: Canvas) -> String {
        let shown = personBlocks(blocks)
        let commandWidth = shown.flatMap { block -> [Int] in
            guard case .commands(_, let shortcuts) = block else { return [] }
            return shortcuts.map { TerminalText.width(line($0.command)) }
        }.max() ?? 0
        let drawn = shown.map { block -> [String] in
            if case .header = block { return [] }
            return lines(block, canvas: canvas, commandWidth: commandWidth)
        }
        let widest = drawn.joined().map(TerminalText.width).max() ?? 0
        let headers = shown.compactMap { block -> Header? in
            if case .header(let header) = block { return header }
            return nil
        }
        let natural = headers.map { naturalWidth($0, style: canvas.style) }.max() ?? 0
        let frame = min(canvas.usable, max(widest, natural, 40))
        var sections: [[String]] = []
        for (block, lines) in zip(shown, drawn) {
            if case .header(let header) = block {
                sections.append(self.header(header, frame: frame, style: canvas.style))
            } else if !lines.isEmpty {
                sections.append(lines)
            }
        }
        guard !sections.isEmpty else { return "" }
        return sections.map { $0.joined(separator: "\n") }.joined(separator: "\n\n") + "\n"
    }

    /// Warnings, then notes, each with its `Try` or `See` line, at most five of a kind; then `Next  <command>` after a blank line.
    public static func notices(_ notices: [Notice], canvas: Canvas, afterBody: Bool) -> String {
        let style = canvas.style
        var lines: [String] = []
        for kind in [Notice.Kind.warning, .note] {
            let ofKind = notices.filter { $0.kind == kind }
            lines += ofKind.prefix(noticesPerKind).flatMap { notice($0, canvas: canvas) }
            if ofKind.count > noticesPerKind {
                lines.append("    " + style.dim(more(ofKind.count - noticesPerKind, style: style)))
            }
        }
        let next = notices.filter { $0.kind == .next }.compactMap(\.command).filter { !$0.isEmpty }
        if !next.isEmpty {
            if !lines.isEmpty { lines.append("") }
            lines += TerminalUI.commands(next.map { ("Next", line($0)) }, indent: "", style: style)
        }
        guard !lines.isEmpty else { return "" }
        return (afterBody ? "\n" : "") + lines.joined(separator: "\n") + "\n"
    }

    /// `❌  ` and the cause in bold red, the rest of the message under it, then `Try  <hint>` unless the message names it.
    public static func error(_ message: String, hint: String?, canvas: Canvas) -> String {
        let style = canvas.style
        var paragraphs = TerminalText.capped(message, cap: TerminalText.maxErrorCharacters)
            .split(separator: "\n", omittingEmptySubsequences: false).map { TerminalText.line(String($0), cap: nil, keepsTab: false) }
        let (headline, rest) = TerminalText.firstSentence(paragraphs.isEmpty ? "" : paragraphs.removeFirst())
        if !rest.isEmpty { paragraphs.insert(rest, at: 0) }
        let lead = style.mark(.cancel) + (style.ascii ? " " : "  ")
        let indent = String(repeating: " ", count: TerminalText.width(lead))
        let width = max(canvas.prose - indent.count, 10)
        var lines = PromptScreen.wrap(headline, width: width).enumerated().map { index, text in
            (index == 0 ? lead : indent) + TerminalText.codeSpans(text, style: style) { style.red(style.bold($0)) }
        }
        for paragraph in paragraphs where !paragraph.trimmingCharacters(in: .whitespaces).isEmpty {
            lines += PromptScreen.wrap(paragraph, width: width).map { indent + TerminalText.codeSpans($0, style: style) }
        }
        if let hint, !hint.isEmpty, !message.contains(hint) {
            lines += TerminalUI.commands([("Try", line(hint))], indent: indent, style: style)
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Prose for a person: wrapped at `width`, never inside a `` `code` `` span, each span cyan without its backticks.
    public static func prose(_ text: String, width: Int, indent: String = "", style: TerminalStyle) -> [String] {
        PromptScreen.wrap(line(text), width: max(width - TerminalText.width(indent), 10)).map { indent + TerminalText.codeSpans($0, style: style) }
    }

    /// A table's rows for a person, under bold group titles with a blank line between groups.
    public static func table(_ table: Table, canvas: Canvas) -> [String] {
        let layout = table.layout(width: canvas.usable)
        let rows = table.personRows
        var lines: [String] = []
        for (index, row) in rows.enumerated() {
            if index == 0 || row.group != rows[index - 1].group {
                if index > 0 { lines.append("") }
                if let group = row.group { lines.append("  " + canvas.style.bold(line(group))) }
            }
            lines += self.row(row, of: table, layout: layout, canvas: canvas)
        }
        return lines
    }

    private static func personBlocks(_ blocks: [Block]) -> [Block] {
        blocks.flatMap { block -> [Block] in
            switch block {
            case .agent: return []
            case .person(let inner): return personBlocks(inner)
            default: return [block]
            }
        }
    }

    /// `commandWidth` lines up the commands of every `commands` block on the page.
    private static func lines(_ block: Block, canvas: Canvas, commandWidth: Int) -> [String] {
        let style = canvas.style
        switch block {
        case .header, .agent, .person:
            return []
        case .table(let table):
            return self.table(table, canvas: canvas)
        case .fields(let fields):
            let labels = fields.map { line($0.label) }
            let widest = labels.map(TerminalText.width).max() ?? 0
            return zip(labels, fields).map { label, field in
                let value = field.value.untrusted ? TerminalText.field(field.value.person ?? field.value.text, profile: .person) : line(field.value.person ?? field.value.text)
                let tag = field.value.tag.map { " " + style.dim(line($0)) } ?? ""
                return "  " + style.dim(label + String(repeating: " ", count: widest - TerminalText.width(label))) + "  " + value + tag
            }
        case .prose(let text):
            return prose(text, width: canvas.prose, indent: "  ", style: style)
        case .outcome(let outcome):
            let details = outcome.details.map(line)
            let lead = style.mark(outcome.ok ? .done : .cancel) + (style.ascii ? " " : "  ")
            let indent = String(repeating: " ", count: TerminalText.width(lead))
            let width = max(canvas.prose - indent.count, 10)
            let paint: (String) -> String = { outcome.ok ? style.green(style.bold($0)) : style.red(style.bold($0)) }
            return PromptScreen.wrap(line(outcome.headline), width: width).enumerated().map { ($0 == 0 ? lead : indent) + paint($1) }
                + details.flatMap { PromptScreen.wrap($0, width: width) }.map { indent + style.dim($0) }
        case .commands(let title, let shortcuts):
            let indent = title == nil ? "  " : "    "
            let commands = shortcuts.map { line($0.command) }
            let widest = max(commands.map(TerminalText.width).max() ?? 0, commandWidth)
            let rows = zip(commands, shortcuts).map { command, shortcut in
                indent + style.cyan(command) + String(repeating: " ", count: widest - TerminalText.width(command)) + "  " + style.dim(line(shortcut.about))
            }
            return (title.map { ["  " + style.bold(line($0))] } ?? []) + rows
        }
    }

    private static func naturalWidth(_ header: Header, style: TerminalStyle) -> Int {
        let title = TerminalText.width((style.ascii ? "" : header.mark.emoji + "  ") + line(header.title))
        let summary = summaryText(header, style: style)
        return title + (summary.isEmpty ? 0 : 2 + TerminalText.width(summary))
    }

    private static func summaryText(_ header: Header, style: TerminalStyle) -> String {
        header.summary.map(line).joined(separator: " \(style.dot) ")
    }

    /// The title line with its summary right-aligned at `frame`, or the summary on the next lines when it does not fit; then the rule.
    public static func header(_ header: Header, frame: Int, style: TerminalStyle) -> [String] {
        let mark = style.ascii ? "" : header.mark.emoji + "  "
        let title = line(header.title)
        let titleWidth = TerminalText.width(mark + title)
        let summary = summaryText(header, style: style)
        var lines: [String]
        if summary.isEmpty {
            lines = [mark + style.bold(title)]
        } else if titleWidth + 2 + TerminalText.width(summary) <= frame {
            lines = [mark + style.bold(title) + String(repeating: " ", count: frame - titleWidth - TerminalText.width(summary)) + style.dim(summary)]
        } else {
            let parts = PromptScreen.pack(header.summary.map(line), separator: " \(style.dot) ", width: max(frame - 4, 10))
            lines = [mark + style.bold(title)] + parts.map { "    " + style.dim($0) }
        }
        return lines + [style.cyan(String(repeating: style.rule, count: frame))]
    }

    private static func row(_ row: Table.Row, of table: Table, layout: Table.Layout, canvas: Canvas) -> [String] {
        let style = canvas.style
        let lead = layout.lead == 4 ? "  " + (row.status.map(style.status) ?? " ") + " " : "  "
        func toned(_ text: String, _ column: Int) -> String {
            guard !text.isEmpty else { return "" }
            switch table.columns[column].tone {
            case .plain: return text
            case .bold: return style.bold(text)
            case .dim: return style.dim(text)
            case .command: return style.cyan(text)
            }
        }
        if layout.stacked {
            let room = canvas.usable - layout.lead
            var parts: [String] = []
            var used = 0
            for placed in layout.shown where table.columns[placed.column].fit != .whole {
                let text = table.personText(row, placed.column)
                guard !text.isEmpty else { continue }
                let tag = table.personTag(row, placed.column)
                let separator = parts.isEmpty ? 0 : 3
                let tagWidth = tag.map { TerminalText.width($0) + 1 } ?? 0
                let left = room - used - separator
                guard left > 0 || table.isWhole(row, placed.column) else { break }
                if TerminalText.width(text) + tagWidth <= left || table.isWhole(row, placed.column) {
                    parts.append(toned(text, placed.column) + (tag.map { " " + style.dim($0) } ?? ""))
                    used += separator + TerminalText.width(text) + tagWidth
                } else {
                    parts.append(toned(TerminalText.truncate(text, to: left, ellipsis: style.ellipsis), placed.column))
                    break
                }
            }
            let whole = layout.shown.filter { table.columns[$0.column].fit == .whole }.compactMap { placed -> String? in
                let text = table.personText(row, placed.column)
                return text.isEmpty ? nil : toned(text, placed.column)
            }
            let first = lead + parts.joined(separator: " \(style.dot) ")
            return whole.isEmpty ? [first] : [first, String(repeating: " ", count: layout.lead) + whole.joined(separator: "  ")]
        }
        var cells: [(text: String, pad: Int)] = []
        for placed in layout.shown {
            var text = table.personText(row, placed.column)
            var tag = table.personTag(row, placed.column)
            let tagWidth = tag.map { TerminalText.width($0) + 1 } ?? 0
            if TerminalText.width(text) + tagWidth > placed.width {
                let cut: TerminalText.Cut
                if case .cut(_, let at) = table.columns[placed.column].fit { cut = at } else { cut = .end }
                if placed.width - tagWidth >= 1 {
                    text = TerminalText.truncate(text, to: placed.width - tagWidth, at: cut, ellipsis: style.ellipsis)
                } else {
                    tag = nil
                    text = TerminalText.truncate(text, to: placed.width, at: cut, ellipsis: style.ellipsis)
                }
            }
            let width = TerminalText.width(text) + (tag.map { TerminalText.width($0) + 1 } ?? 0)
            cells.append((toned(text, placed.column) + (tag.map { " " + style.dim($0) } ?? ""), placed.width - width))
        }
        while let last = cells.last, last.text.isEmpty { cells.removeLast() }
        let body = cells.enumerated().map { index, cell in
            index == cells.count - 1 ? cell.text : cell.text + String(repeating: " ", count: max(cell.pad, 0))
        }
        return [lead + body.joined(separator: "  ")]
    }

    private static func notice(_ notice: Notice, canvas: Canvas) -> [String] {
        let style = canvas.style
        let warning = notice.kind == .warning
        let lead = style.mark(notice.mark ?? (warning ? .warning : .tip)) + (style.ascii ? " " : "  ")
        let indent = String(repeating: " ", count: TerminalText.width(lead))
        let tone: (String) -> String = warning ? style.yellow : { $0 }
        var lines = PromptScreen.wrap(line(notice.text), width: max(canvas.prose - indent.count, 10)).enumerated().map { index, text in
            (index == 0 ? tone(lead) : indent) + TerminalText.codeSpans(text, style: style, base: tone)
        }
        if let command = notice.command, !command.isEmpty {
            lines += TerminalUI.commands([(notice.label, line(command))], indent: indent, style: style)
        }
        return lines
    }

    private static func more(_ count: Int, style: TerminalStyle) -> String {
        "\(style.ellipsis)and \(count) more"
    }

    private static func line(_ text: String) -> String {
        TerminalText.line(text, cap: TerminalText.maxErrorCharacters, keepsTab: false)
    }
}
