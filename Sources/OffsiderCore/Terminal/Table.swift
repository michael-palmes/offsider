import Foundation

/// Rows described once and drawn twice: a fixed agent table, and a person's grouped rows fitted to the terminal.
public struct Table: Sendable {
    public struct Column: Sendable {
        /// The agent header title; nil leaves the column out for agents.
        public var agent: String?
        /// Where the column sits in a person's row; nil leaves it out for people.
        public var person: Int?
        public var fit: Fit
        public var tone: Tone

        public init(agent: String?, person: Int?, fit: Fit = .whole, tone: Tone = .plain) {
            self.agent = agent
            self.person = person
            self.fit = fit
            self.tone = tone
        }
    }

    /// How a person's column gives way: never (`whole`, for IDs and commands), cut down to `min` columns, or dropped by priority.
    public enum Fit: Sendable, Equatable {
        case whole
        case cut(min: Int, at: TerminalText.Cut = .end)
        case optional(priority: Int)
    }

    public enum Tone: Sendable, Equatable {
        case plain, bold, dim, command
    }

    public struct Cell: Sendable, Equatable {
        public var text: String
        /// Text from a device or app: JSON-quoted for an agent, escaped for both.
        public var untrusted: Bool
        /// What a person sees when it differs; `""` hides the cell from people.
        public var person: String?
        /// An agent reads `text (tag)`; a person sees the tag dim after the text.
        public var tag: String?
        /// Never cut for a person, whatever its column's fit: a name that is also the ID, such as an AVD's.
        public var whole: Bool

        public init(_ text: String, untrusted: Bool = false, person: String? = nil, tag: String? = nil, whole: Bool = false) {
            self.text = text
            self.untrusted = untrusted
            self.person = person
            self.tag = tag
            self.whole = whole
        }
    }

    public struct Row: Sendable {
        public var cells: [Cell?]
        public var status: RowStatus?
        /// The section a person sees the row under; an agent's rows keep their order.
        public var group: String?

        public init(_ cells: [Cell?], status: RowStatus? = nil, group: String? = nil) {
            self.cells = cells
            self.status = status
            self.group = group
        }
    }

    public var columns: [Column]
    public var rows: [Row]
    /// The most characters one agent cell shows.
    public var agentCap: Int
    /// The order a person sees groups in; groups not named here follow in the order their first row comes.
    public var groupOrder: [String]

    public init(columns: [Column], rows: [Row] = [], agentCap: Int = TerminalText.maxCharacters, groupOrder: [String] = []) {
        self.columns = columns
        self.rows = rows
        self.agentCap = agentCap
        self.groupOrder = groupOrder
    }

    /// The rows as a person sees them: each group's rows together, groups in `groupOrder` first.
    public var personRows: [Row] {
        var groups: [String?] = groupOrder
        for row in rows where !groups.contains(row.group) { groups.append(row.group) }
        return groups.flatMap { group in rows.filter { $0.group == group } }
    }
}

extension Table {
    /// How a person's rows fit `width` columns: each shown column's width, or stacked onto two lines.
    public struct Layout: Sendable, Equatable {
        public struct Placed: Sendable, Equatable {
            public var column: Int
            /// The columns it is drawn in; 0 when stacked.
            public var width: Int
        }

        /// The columns a person sees, in their order.
        public var shown: [Placed]
        public var stacked: Bool
        /// Columns before the row text: the indent, the status dot and a space.
        public var lead: Int
    }

    /// The columns a person can see, in their order.
    var personColumns: [Int] {
        columns.indices.filter { columns[$0].person != nil }.sorted { (columns[$0].person ?? 0, $0) < (columns[$1].person ?? 0, $1) }
    }

    /// The cell's text as a person reads it, escaped and capped, without its tag.
    func personText(_ row: Row, _ column: Int) -> String {
        guard column < row.cells.count, let cell = row.cells[column] else { return "" }
        let text = cell.person ?? cell.text
        guard !text.isEmpty else { return "" }
        return cell.untrusted ? TerminalText.field(text, cap: agentCap, profile: .person) : TerminalText.line(text, cap: agentCap, keepsTab: false)
    }

    /// The tag a person sees after the cell, or nil when the cell is hidden or has none.
    func personTag(_ row: Row, _ column: Int) -> String? {
        guard column < row.cells.count, let cell = row.cells[column], let tag = cell.tag, !(cell.person ?? cell.text).isEmpty else { return nil }
        return TerminalText.line(tag, cap: agentCap, keepsTab: false)
    }

    func isWhole(_ row: Row, _ column: Int) -> Bool {
        columns[column].fit == .whole || (column < row.cells.count && row.cells[column]?.whole == true)
    }

    func naturalWidth(_ row: Row, _ column: Int) -> Int {
        let text = personText(row, column)
        return TerminalText.width(text) + (personTag(row, column).map { TerminalText.width($0) + 1 } ?? 0)
    }

    /// Fits all rows at once, so columns line up across groups: drop optional columns, cut to minimums, then stack.
    public func layout(width usable: Int) -> Layout {
        let lead = rows.contains { $0.status != nil } ? 4 : 2
        var widths: [Int: Int] = [:]
        for column in personColumns {
            let natural = rows.map { naturalWidth($0, column) }.max() ?? 0
            if natural > 0 { widths[column] = natural }
        }
        var shown = personColumns.filter { widths[$0] != nil }
        func total() -> Int { shown.reduce(0) { $0 + (widths[$1] ?? 0) } + max(shown.count - 1, 0) * 2 }
        let available = usable - lead
        let optional = shown.compactMap { column -> (Int, Int)? in
            if case .optional(let priority) = columns[column].fit { return (priority, column) }
            return nil
        }.sorted { $0 < $1 }
        for (_, column) in optional where total() > available {
            shown.removeAll { $0 == column }
        }
        let floors = Dictionary(uniqueKeysWithValues: shown.map { column in
            (column, rows.filter { isWhole($0, column) }.map { naturalWidth($0, column) }.max() ?? 0)
        })
        while total() > available {
            let cuttable = shown.compactMap { column -> (width: Int, column: Int)? in
                guard case .cut(let minimum, _) = columns[column].fit, let width = widths[column], width > max(minimum, floors[column] ?? 0) else { return nil }
                return (width, column)
            }
            guard let widest = cuttable.max(by: { ($0.width, -$0.column) < ($1.width, -$1.column) }) else { break }
            widths[widest.column] = widest.width - 1
        }
        guard total() <= available else {
            let natural = personColumns.filter { column in rows.contains { naturalWidth($0, column) > 0 } }
            return Layout(shown: natural.map { Layout.Placed(column: $0, width: 0) }, stacked: true, lead: lead)
        }
        return Layout(shown: shown.map { Layout.Placed(column: $0, width: widths[$0] ?? 0) }, stacked: false, lead: lead)
    }
}
