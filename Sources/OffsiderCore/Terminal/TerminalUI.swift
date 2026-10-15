import Foundation

/// The terminal UI kit every interactive Offsider command draws with. Each piece returns lines and never writes, so it is
/// tested without a terminal; `TerminalPrompt` draws them, erases them and reads keys.
///
/// - `banner`: a cyan double rule as wide as `width`, the emoji and bold title (at most 8 words), the rule again. No intro under it.
/// - `question`: an optional dim `1/4`, the bold question (at most 5 words), its dim controls beside it: `(↑↓, Enter, Q quit)`.
/// - `menu`: the question, a blank line, then one row per option: cursor `▸` and row green, an emoji and two spaces, columns
///   aligned, the last column dim, `(Recommended)` magenta, rows that cannot be chosen dim. A warning goes yellow under the rows.
/// - `receipt`: what an answered question collapses to, `✅ Device    iPad Pro`, labels padded so the lines read as one receipt.
/// - `summary`: one bold line of parts joined by ` · `, broken only between parts.
/// - `closing`: the bold green `✅` headline, then dim labels with cyan commands that never wrap.
/// - `warning`: a yellow `⚠️` line, wrapped.
/// - `spinnerFrames`: what `TerminalSpinner` cycles through while a slow read runs.
///
/// With `style.ascii` every emoji becomes a short tag (`[iPhone]`, `[OK]`, `[x]`), `▸` becomes `>` and the rules `=`;
/// with `style.colours` off nothing carries an escape. Prose wraps at `width`, which `PromptScreen.width(columns:)` caps at 72.
public enum TerminalUI {
    public static func banner(_ title: String, mark: TerminalStyle.Mark, width: Int, style: TerminalStyle) -> [String] {
        let rule = style.cyan(String(repeating: style.heavyRule, count: width))
        let head = style.ascii ? title : mark.emoji + "  " + title
        return [rule, style.bold("  " + head), rule]
    }

    /// The keys a menu takes: moving and choosing only when a row can be chosen, R only with a rescan, and what Q means.
    public struct Controls: Equatable, Sendable {
        public var choosing: Bool
        public var rescan: Bool
        public var quit: String
        /// Space ticks rows, for a menu that takes several.
        public var ticking: Bool

        public init(choosing: Bool = true, rescan: Bool = false, quit: String = "quit", ticking: Bool = false) {
            self.choosing = choosing
            self.rescan = rescan
            self.quit = quit
            self.ticking = ticking
        }

        public func text(style: TerminalStyle) -> String {
            let keys = (choosing ? [style.upDown] + (ticking ? ["Space"] : []) + ["Enter"] : []) + (rescan ? ["R rescan"] : []) + ["Q \(quit)"]
            return "(" + keys.joined(separator: ", ") + ")"
        }
    }

    /// `1/4 Which app? (↑↓, Enter, Q quit)` on one line, or the controls on the next when both would pass `width`.
    public static func question(_ text: String, step: String? = nil, controls: Controls, width: Int, style: TerminalStyle) -> [String] {
        let keys = controls.text(style: style)
        let lead = step.map { style.dim($0) + " " } ?? ""
        guard TerminalText.width(lead + text + " " + keys) > width else { return [lead + style.bold(text) + " " + style.dim(keys)] }
        return [lead + style.bold(text), style.dim(keys)]
    }

    public static func menu(
        _ question: String?, step: String? = nil, rows: [MenuRow], selected: Int?, controls: Controls, warning: String? = nil, notes: [String] = [],
        commands: [(label: String, command: String)] = [], width: Int = 72, window: Int? = nil, style: TerminalStyle
    ) -> String {
        var lines = question.map { self.question($0, step: step, controls: controls, width: width, style: style) + [""] } ?? []
        lines += self.window(self.rows(rows, selected: selected, style: style), around: selected ?? 0, size: window, style: style)
        if let warning { lines += self.warning(warning, width: width, style: style).map { "  " + $0 } }
        lines += notes.flatMap { PromptScreen.wrap($0, width: width - 2) }.map { "  " + style.dim($0) }
        lines += self.commands(commands, indent: "  ", style: style)
        return lines.joined(separator: "\n")
    }

    /// Menu rows: `  ▸ 📱  name  tail (Recommended)`, the marks padded to one width so the columns line up under ASCII tags too.
    /// Rows are never wrapped, so their columns hold; the terminal folds one wider than itself and the redraw counts that.
    public static func rows(_ rows: [MenuRow], selected: Int?, style: TerminalStyle) -> [String] {
        let marks = rows.map { $0.mark.map(style.mark) }
        let markWidth = marks.compactMap { $0.map(TerminalText.width) }.max()
        let columns = rows.map(\.columns.count).max() ?? 0
        let widths = (0..<max(columns - 1, 0)).map { column in
            rows.filter { $0.columns.count > 1 && column < $0.columns.count - 1 }.map { TerminalText.width($0.columns[column]) }.max() ?? 0
        }
        func pad(_ text: String, _ to: Int) -> String { text + String(repeating: " ", count: max(to - TerminalText.width(text), 0)) }
        return rows.enumerated().map { index, row -> String in
            var cells = row.columns.enumerated().map { column, text in
                column < row.columns.count - 1 && row.columns.count > 1 ? pad(text, widths[column]) : text
            }
            let lead = markWidth.map { pad(marks[index] ?? "", $0) + "  " } ?? ""
            let body: String
            if !row.enabled {
                body = "    " + style.dim(lead + cells.joined(separator: "  "))
            } else {
                let tail = cells.count > 1 ? cells.removeLast() : nil
                let head = lead + cells.joined(separator: "  ")
                let shown = index == selected ? "  " + style.green(style.pointer + " " + head) : "    " + head
                body = shown + (tail.map { "  " + style.dim($0) } ?? "") + (row.recommended ? " " + style.magenta("(\(recommended))") : "")
            }
            return body
        }
    }

    /// At most `size` of `rows`, scrolled to keep row `around` in view, with a dim count of the rows hidden above and below.
    public static func window(_ rows: [String], around: Int, size: Int?, style: TerminalStyle) -> [String] {
        guard let size, size >= 3, rows.count > size else { return rows }
        let start = min(max(around - size / 2, 0), rows.count - size)
        let below = rows.count - start - size
        return (start > 0 ? ["    " + style.dim("\(start) more above")] : []) + rows[start..<start + size]
            + (below > 0 ? ["    " + style.dim("\(below) more below")] : [])
    }

    /// `[x]` for a ticked row, `[ ]` for one that is not, as the first column of a menu that takes several.
    public static func box(_ ticked: Bool) -> String { ticked ? "[x]" : "[ ]" }

    public static let recommended = "Recommended"

    /// What a closed menu leaves when the caller keeps no receipt of its own: `  ▸ Second`.
    public static func chosen(_ option: String, style: TerminalStyle) -> String {
        "  " + style.green(style.pointer + " " + option)
    }

    public static let receiptLabelWidth = 8

    public static func receipt(_ label: String, _ value: String, labelWidth: Int = receiptLabelWidth, style: TerminalStyle) -> String {
        style.mark(.done) + " " + style.dim(label + String(repeating: " ", count: max(labelWidth - TerminalText.width(label), 0))) + "  " + value
    }

    public static func summary(_ mark: TerminalStyle.Mark?, _ parts: [String], width: Int, style: TerminalStyle) -> [String] {
        let lead = mark.map { style.mark($0) + " " } ?? ""
        let indent = String(repeating: " ", count: TerminalText.width(lead))
        return PromptScreen.pack(parts, separator: " \(style.dot) ", width: width - TerminalText.width(lead), indent: "")
            .enumerated().map { $0 == 0 ? lead + style.bold($1) : indent + style.bold($1) }
    }

    /// The end of a run: the headline, dim notes, then `Label  command` lines with labels padded and commands never wrapped.
    public static func closing(_ headline: String, notes: [String] = [], commands: [(label: String, command: String)], width: Int, style: TerminalStyle) -> [String] {
        let lead = style.mark(.done) + " "
        let indent = String(repeating: " ", count: TerminalText.width(lead))
        let head = PromptScreen.wrap(headline, width: max(width - indent.count, 10))
        return [lead + style.green(style.bold(head[0]))]
            + head.dropFirst().map { indent + style.green(style.bold($0)) }
            + notes.flatMap { PromptScreen.wrap($0, width: max(width - indent.count, 10)) }.map { indent + style.dim($0) }
            + self.commands(commands, indent: indent, style: style)
    }

    /// `Label  command` lines: dim labels padded to one width, cyan commands that never wrap.
    public static func commands(_ commands: [(label: String, command: String)], indent: String, style: TerminalStyle) -> [String] {
        let labelWidth = commands.map { TerminalText.width($0.label) }.max() ?? 0
        return commands.map { indent + style.dim($0.label + String(repeating: " ", count: labelWidth - TerminalText.width($0.label))) + "  " + style.cyan($0.command) }
    }

    public static func warning(_ text: String, width: Int, style: TerminalStyle) -> [String] {
        let lead = style.mark(.warning) + (style.ascii ? " " : "  ")
        let indent = String(repeating: " ", count: style.ascii ? lead.count : 3)
        return PromptScreen.wrap(text, width: max(width - indent.count, 10)).enumerated().map { style.yellow(($0 == 0 ? lead : indent) + $1) }
    }

    public static func spinnerFrames(style: TerminalStyle) -> [String] {
        style.ascii ? ["|", "/", "-", "\\"] : ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]
    }
}

/// One menu row: an optional leading mark, columns drawn aligned with the rows around it, a magenta `(Recommended)`,
/// and whether the cursor may land on it.
public struct MenuRow: Equatable, Sendable {
    public var mark: TerminalStyle.Mark?
    public var columns: [String]
    public var recommended: Bool
    public var enabled: Bool

    public init(_ mark: TerminalStyle.Mark? = nil, _ columns: [String], recommended: Bool = false, enabled: Bool = true) {
        self.mark = mark
        self.columns = columns
        self.recommended = recommended
        self.enabled = enabled
    }

    public init(_ columns: [String], recommended: Bool = false, enabled: Bool = true) {
        self.init(nil, columns, recommended: recommended, enabled: enabled)
    }
}
