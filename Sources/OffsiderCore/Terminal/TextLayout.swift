import Foundation

extension TerminalText {
    /// Where a cut leaves out text: at the end, or in the middle so both ends stay.
    public enum Cut: Sendable, Equatable {
        case end, middle
    }

    /// `path` with the home folder written `~`.
    public static func homePath(_ path: String, home: String = NSHomeDirectory()) -> String {
        guard home.count > 1 else { return path }
        let folder = home.hasSuffix("/") ? String(home.dropLast()) : home
        if path == folder { return "~" }
        return path.hasPrefix(folder + "/") ? "~" + path.dropFirst(folder.count) : path
    }

    /// Plain `text` cut by whole characters to fill at most `width` columns, `ellipsis` marking the cut; unchanged when it fits.
    public static func truncate(_ text: String, to width: Int, at cut: Cut = .end, ellipsis: String = "…") -> String {
        guard width > 0 else { return "" }
        guard self.width(text) > width else { return text }
        let mark = self.width(ellipsis)
        guard width > mark else { return mark <= width ? ellipsis : "" }
        let budget = width - mark
        func prefix(_ characters: some Sequence<Character>, fitting room: Int) -> (text: [Character], width: Int) {
            var kept: [Character] = []
            var used = 0
            for character in characters {
                let next = self.width(character)
                guard used + next <= room else { break }
                kept.append(character)
                used += next
            }
            return (kept, used)
        }
        switch cut {
        case .end:
            return String(prefix(text, fitting: budget).text) + ellipsis
        case .middle:
            let head = prefix(text, fitting: (budget + 1) / 2)
            let tail = prefix(text.reversed(), fitting: budget - head.width)
            return String(head.text) + ellipsis + String(tail.text.reversed())
        }
    }

    /// The first sentence of `text` and the rest: a full stop and a space before a capital letter or `` ` `` ends it.
    public static func firstSentence(_ text: String) -> (first: String, rest: String) {
        var index = text.startIndex
        while let stop = text[index...].range(of: ". ") {
            let after = text[stop.upperBound...].drop { $0 == " " }
            if let next = after.first, next.isUppercase || next == "`" {
                return (String(text[..<stop.lowerBound]) + ".", String(after))
            }
            index = stop.upperBound
        }
        return (text, "")
    }

    /// `line` with each balanced `` `code` `` span drawn cyan without its backticks; `base` styles the text around the spans.
    public static func codeSpans(_ line: String, style: TerminalStyle, base: (String) -> String = { $0 }) -> String {
        let parts = line.split(separator: "`", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 3 else { return line.isEmpty ? "" : base(line) }
        let paired = parts.count % 2 == 1 ? parts.count : parts.count - 1
        var output = ""
        for (index, part) in parts.enumerated() {
            if index >= paired {
                output += base("`" + part)
            } else if index % 2 == 1 {
                output += style.cyan(part)
            } else if !part.isEmpty {
                output += base(part)
            }
        }
        return output
    }
}
