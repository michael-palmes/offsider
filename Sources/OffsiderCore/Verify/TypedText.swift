import Foundation

/// Whether a field holds the text `type --verify` sent; the report gives only this, never the text or its length.
public enum TextCheck: String, Sendable {
    case match
    case differs
    case unknown
}

/// Judges a field's value against the text sent into it, folded for case and spacing.
public enum TypedText {
    /// Longer text may be cut in a tree read, so it is never judged.
    public static let longest = 500

    /// `sent` in order in what the field gained (with `replacing`, its whole value and nothing more at the ends); a moved value holding none of it says nothing.
    public static func judge(sent: String, before: String?, after: String?, replacing: Bool) -> TextCheck {
        guard let after, sent.count <= longest, after.count <= longest else { return .unknown }
        let wanted = fold(sent)
        let now = fold(after)
        let was = fold(before ?? "")
        // An emptied field can read as its placeholder, so clearing it never differs.
        guard !wanted.isEmpty else { return now.isEmpty ? .match : .unknown }
        let gained = replacing ? now : inserted(from: was, to: now)
        if isSubsequence(wanted, of: gained), !replacing || endsAgree(wanted, gained) {
            return .match
        }
        // A value read before the keys may have been the placeholder, which shares no text with what replaced it.
        if !replacing, now != was, isSubsequence(wanted, of: now) {
            return .match
        }
        if now != was, !holdsRun(of: wanted, in: gained) {
            return .unknown
        }
        return .differs
    }

    private static func fold(_ text: String) -> [Character] {
        Array(SelectorText.folded(text).lowercased())
    }

    /// What lies between the longest shared start and the longest shared end of `before` and `after`.
    private static func inserted(from before: [Character], to after: [Character]) -> [Character] {
        var start = 0
        while start < before.count, start < after.count, before[start] == after[start] { start += 1 }
        var end = 0
        while end < before.count - start, end < after.count - start, before[before.count - 1 - end] == after[after.count - 1 - end] { end += 1 }
        return Array(after[start..<(after.count - end)])
    }

    private static func isSubsequence(_ needle: [Character], of haystack: [Character]) -> Bool {
        var index = needle.startIndex
        for character in haystack where index < needle.endIndex && character == needle[index] {
            index += 1
        }
        return index == needle.endIndex
    }

    /// The value's first and last letter or digit are the sent text's own.
    private static func endsAgree(_ wanted: [Character], _ value: [Character]) -> Bool {
        let isText: (Character) -> Bool = { $0.isLetter || $0.isNumber }
        return value.first(where: isText) == wanted.first(where: isText) && value.last(where: isText) == wanted.last(where: isText)
    }

    /// Any two characters in a row of `wanted` appear together in `value`; one character when that is all there is.
    private static func holdsRun(of wanted: [Character], in value: [Character]) -> Bool {
        let length = min(2, wanted.count)
        let text = String(value)
        return (0...(wanted.count - length)).contains { text.contains(String(wanted[$0..<($0 + length)])) }
    }
}
