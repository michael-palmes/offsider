import Foundation

/// The terminal UI kit's palette and glyphs, one per stream. Colour only for a terminal, never with `NO_COLOR` or `TERM=dumb`;
/// ASCII glyphs and tags (`[iPhone]`, `[OK]`, `>`, `=`, `-`) with `NO_COLOR` or a locale that is not UTF-8.
/// Roles: cyan for rules and structure, green for the cursor row and success, magenta for `(Recommended)`, yellow for
/// warnings, dim for secondary detail, bold for the question. Nothing else is coloured.
public struct TerminalStyle: Equatable, Sendable {
    public let colours: Bool
    public let ascii: Bool

    public init(colours: Bool, ascii: Bool = false) {
        self.colours = colours
        self.ascii = ascii
    }

    public static let plain = TerminalStyle(colours: false)

    public static func detect(isTerminal: Bool, environment: [String: String] = ProcessInfo.processInfo.environment) -> TerminalStyle {
        let noColour = environment["NO_COLOR"].map { !$0.isEmpty } ?? false
        return TerminalStyle(colours: isTerminal && !noColour && environment["TERM"] != "dumb", ascii: noColour || !isUTF8(environment))
    }

    /// The first locale variable set decides; with none set, macOS terminals are UTF-8.
    static func isUTF8(_ environment: [String: String]) -> Bool {
        guard let locale = ["LC_ALL", "LC_CTYPE", "LANG"].lazy.compactMap({ environment[$0] }).first(where: { !$0.isEmpty }) else { return true }
        let lowered = locale.lowercased()
        return lowered.contains("utf-8") || lowered.contains("utf8")
    }

    public var pointer: String { ascii ? ">" : "▸" }
    public var tick: String { mark(.done) }
    public var rule: String { ascii ? "-" : "─" }
    public var heavyRule: String { ascii ? "=" : "═" }
    public var dot: String { ascii ? "-" : "·" }
    public var ellipsis: String { ascii ? "..." : "…" }
    public var picked: String { pointer }
    public var upDown: String { ascii ? "up/down" : "↑↓" }

    /// An emoji that leads a row or line, or its short ASCII tag. Every emoji here is one scalar drawn two columns wide,
    /// except `warning`, which needs its variation selector and so is followed by two spaces wherever it is used.
    public enum Mark: Sendable, CaseIterable {
        case lock, iPhone, iPad, android, team, app, anyApp, time, keep, type, done, cancel, warning, another, digits

        public var emoji: String {
            switch self {
            case .lock: return "🔐"
            case .iPhone: return "📱"
            case .iPad: return "📲"
            case .android: return "🤖"
            case .team: return "🏢"
            case .app: return "📦"
            case .anyApp: return "✨"
            case .time: return "⏳"
            case .keep: return "📌"
            case .type: return "📝"
            case .done: return "✅"
            case .cancel: return "❌"
            case .warning: return "⚠️"
            case .another: return "➕"
            case .digits: return "🔢"
            }
        }

        public var tag: String {
            switch self {
            case .lock: return "[lock]"
            case .iPhone: return "[iPhone]"
            case .iPad: return "[iPad]"
            case .android: return "[Android]"
            case .team: return "[team]"
            case .app: return "[app]"
            case .anyApp: return "[any]"
            case .time: return "[time]"
            case .keep: return "[keep]"
            case .type: return "[type]"
            case .done: return "[OK]"
            case .cancel: return "[x]"
            case .warning: return "[!]"
            case .another: return "[+]"
            case .digits: return "[id]"
            }
        }
    }

    public func mark(_ mark: Mark) -> String { ascii ? mark.tag : mark.emoji }

    public func bold(_ text: String) -> String { sgr("1", text) }
    public func dim(_ text: String) -> String { sgr("2", text) }
    public func green(_ text: String) -> String { sgr("32", text) }
    public func red(_ text: String) -> String { sgr("31", text) }
    public func yellow(_ text: String) -> String { sgr("33", text) }
    public func cyan(_ text: String) -> String { sgr("36", text) }
    public func magenta(_ text: String) -> String { sgr("35", text) }

    private func sgr(_ code: String, _ text: String) -> String {
        colours ? "\u{1B}[\(code)m\(text)\u{1B}[0m" : text
    }
}

/// Terminal cell maths for text Offsider draws, so a redraw can move back over exactly what it wrote.
public enum TerminalText {
    public static func stripStyle(_ text: String) -> String {
        var out = String.UnicodeScalarView()
        var scalars = text.unicodeScalars.makeIterator()
        while let scalar = scalars.next() {
            guard scalar == "\u{1B}" else {
                out.append(scalar)
                continue
            }
            guard scalars.next() == "[" else { continue }
            while let next = scalars.next(), !(0x40...0x7E).contains(next.value) {}
        }
        return String(out)
    }

    /// Columns `text` fills: emoji and East Asian wide characters take two, joiners and variation selectors none.
    public static func width(_ text: String) -> Int {
        stripStyle(text).unicodeScalars.reduce(0) { $0 + cells($1) }
    }

    /// Rows `text` fills on a terminal `columns` wide; an empty line still takes one.
    public static func rows(_ text: String, columns: Int) -> Int {
        let columns = max(columns, 1)
        return text.split(separator: "\n", omittingEmptySubsequences: false).reduce(0) { total, line in
            total + max(1, (width(String(line)) + columns - 1) / columns)
        }
    }

    /// Moves the cursor from the end of a one-line draw `width` columns wide back to column `target` of it, and says which row it lands on.
    public static func cursorMove(width: Int, to target: Int, columns: Int) -> (sequence: String, row: Int) {
        let columns = max(columns, 1)
        let lastRow = max(0, (width + columns - 1) / columns - 1)
        guard target >= 0, target < width else { return ("", lastRow) }
        let row = target / columns
        let up = lastRow - row
        return ((up > 0 ? "\u{1B}[\(up)A" : "") + "\u{1B}[\(target % columns + 1)G", row)
    }

    private static func cells(_ scalar: Unicode.Scalar) -> Int {
        let value = scalar.value
        if value < 0x20 || (0x7F..<0xA0).contains(value) { return 0 }
        if (0x0300...0x036F).contains(value) || (0xFE00...0xFE0F).contains(value) || value == 0x200D { return 0 }
        if wide.contains(where: { $0.contains(value) }) { return 2 }
        return 1
    }

    private static let wide: [ClosedRange<UInt32>] = [
        0x1100...0x115F, 0x231A...0x231B, 0x23E9...0x23EC, 0x23F0...0x23F0, 0x23F3...0x23F3,
        0x25FD...0x25FE, 0x2614...0x2615, 0x2648...0x2653, 0x267F...0x267F, 0x2693...0x2693,
        0x26A1...0x26A1, 0x26AA...0x26AB, 0x26BD...0x26BE, 0x26C4...0x26C5, 0x26CE...0x26CE,
        0x26D4...0x26D4, 0x26EA...0x26EA, 0x26F2...0x26F3, 0x26F5...0x26F5, 0x26FA...0x26FA,
        0x26FD...0x26FD, 0x2705...0x2705, 0x270A...0x270B, 0x2728...0x2728, 0x274C...0x274C,
        0x274E...0x274E, 0x2753...0x2755, 0x2757...0x2757, 0x2795...0x2797, 0x27B0...0x27B0,
        0x27BF...0x27BF, 0x2B1B...0x2B1C, 0x2B50...0x2B50, 0x2B55...0x2B55, 0x2E80...0xA4CF,
        0xAC00...0xD7A3, 0xF900...0xFAFF, 0xFE30...0xFE4F, 0xFF00...0xFF60, 0xFFE0...0xFFE6,
        0x1F004...0x1F004, 0x1F0CF...0x1F0CF, 0x1F18E...0x1F18E, 0x1F191...0x1F19A, 0x1F1E6...0x1F1FF,
        0x1F200...0x1F2FF, 0x1F300...0x1F64F, 0x1F680...0x1F6FF, 0x1F7E0...0x1F7EB, 0x1F900...0x1F9FF,
        0x1FA70...0x1FAFF, 0x20000...0x3FFFD,
    ]
}
