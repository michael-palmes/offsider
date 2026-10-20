import Foundation

/// The words and layout of the prompts Offsider shows a person at a terminal. Nothing here prints a secret.
public enum PromptScreen {
    public static let cancelledNothingSaved = "👋 Cancelled, nothing saved."
    public static let cancelledNothingLinked = "👋 Cancelled, nothing linked."
    public static let mismatch = "❌ Those didn't match. Try again."
    public static let untypeable = "❗ Use characters a keyboard can type (no accents or emoji)."


    /// Prompt labels padded to one width, so the answers line up.
    public static func labels(_ labels: [String]) -> [String] {
        let widest = labels.map(TerminalText.width).max() ?? 0
        return labels.map { $0 + String(repeating: " ", count: widest - TerminalText.width($0) + 2) }
    }

    /// The widest a block of prose runs: the terminal, at most 72 columns, never under 20.
    public static func width(columns: Int?) -> Int {
        min(max(columns ?? 72, 20), 72)
    }

    /// `text` broken between words to fit `width`; continuation lines start with `indent`. Runs of spaces inside a line stay,
    /// so columns keep their alignment; a word wider than a line stays whole, and so does a balanced `` `code` `` span.
    public static func wrap(_ text: String, width: Int, indent: String = "") -> [String] {
        var lines: [String] = []
        var line = ""
        var gap = ""
        var word = ""
        var ticks = text.reduce(0) { $1 == "`" ? $0 + 1 : $0 }
        var inCode = false
        func place() {
            guard !word.isEmpty else { return }
            if line.isEmpty || TerminalText.width(line + gap + word) <= width {
                line += gap + word
            } else {
                lines.append(line)
                line = indent + word
            }
            gap = ""
            word = ""
        }
        for character in text {
            if character == "`" {
                if inCode || ticks >= 2 { inCode.toggle() }
                ticks -= 1
            }
            if character == " ", !inCode {
                if !word.isEmpty { place() }
                gap.append(character)
            } else {
                word.append(character)
            }
        }
        place()
        return lines + [line]
    }

    /// `parts` joined by `separator`, breaking lines only between parts, so a phrase such as `team ABCDE12345` stays whole.
    public static func pack(_ parts: [String], separator: String, width: Int, indent: String = "") -> [String] {
        var lines: [String] = []
        var line = ""
        for part in parts {
            if line.isEmpty {
                line = (lines.isEmpty ? "" : indent) + part
            } else if TerminalText.width(line + separator + part) <= width {
                line += separator + part
            } else {
                lines.append(line + String(separator.reversed().drop { $0 == " " }.reversed()))
                line = indent + part
            }
        }
        return lines + [line]
    }

    /// One bullet per character typed, never the characters.
    public static func dots(_ count: Int) -> String {
        String(repeating: "•", count: count)
    }

    /// Typed text as drawn: a control, bidi, zero-width or other invisible character shows as `?`, never as itself.
    public static func visible(_ text: String) -> String {
        var previous: Unicode.Scalar?
        return String(String.UnicodeScalarView(text.unicodeScalars.map { scalar in
            defer { previous = scalar }
            return TerminalText.isHazard(scalar, after: previous) ? "?" : scalar
        }))
    }

    /// A name or ID from a device or the Keychain, for a menu row, receipt or summary: `visible`, and cut so it stays on one row.
    public static func label(_ text: String, cap: Int = 60) -> String {
        visible(TerminalText.capped(text, cap: cap))
    }

    /// A command to run next under a report's headline: the label dim, the command cyan and never wrapped.
    public static func nextStep(_ label: String, command: String, style: TerminalStyle) -> String {
        "   " + style.dim(label) + "  " + style.cyan(command)
    }
}
