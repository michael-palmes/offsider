import Foundation

enum AdbShellQuoting {
    /// One POSIX single-quoted word; an embedded quote becomes `'\''`.
    static func quote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }

    /// `input text` commands for printable ASCII. Spaces go as `%s`, which `input text` turns back into spaces,
    /// so a literal `%s` is split across two calls (`...%` then `s...`) to keep it literal.
    static func inputTextCommands(for text: String) -> [String] {
        var pieces: [String] = []
        var current = ""
        var previous: Character?
        for character in text {
            if character == "s", previous == "%" {
                pieces.append(current)
                current = ""
            }
            current.append(character)
            previous = character
        }
        pieces.append(current)
        return pieces
            .filter { !$0.isEmpty }
            .map { "input text " + quote($0.replacingOccurrences(of: " ", with: "%s")) }
    }
}
