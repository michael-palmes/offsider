import Foundation

/// Text from the device under test made safe for a terminal or an agent: control, bidi, invisible and tag characters
/// show as JSON-style escapes (`\u001b`), and long text is cut at a grapheme boundary with `…(+N)`.
extension TerminalText {
    /// The most characters one untrusted string shows before `…(+N)` replaces the rest.
    public static let maxCharacters = 500

    /// How many scalars past `cap` a cut may run to finish the character it is in; a longer character is cut inside.
    public static let graphemeOverrun = 100

    /// C0, DEL, C1, the soft hyphen, bidi controls and isolates, zero-width and invisible operators and format characters,
    /// line and paragraph separators, variation selectors, the byte-order mark, interlinear annotation and tag characters.
    /// Joiners (U+200C, U+200D) are not hazards, nor are the presentation selectors U+FE0E and U+FE0F on their own: see `isHazard(_:after:)`.
    @inline(__always)
    public static func isHazard(_ scalar: Unicode.Scalar) -> Bool {
        let value = scalar.value
        if value < 0x20 || value == 0x7F { return true }
        if value < 0x80 { return false }
        if value < 0xA0 || value == 0xAD { return true }
        if value < 0x061C { return false }
        switch value {
        case 0x061C, 0x180E, 0x200B, 0x200E, 0x200F, 0x2028, 0x2029, 0x202A...0x202E, 0x2060...0x2064, 0x2066...0x206F,
             0xFE00...0xFE0D, 0xFEFF, 0xFFF9...0xFFFB, 0xE0000...0xE007F, 0xE0100...0xE01EF:
            return true
        default:
            return false
        }
    }

    /// A presentation selector (U+FE0E, U+FE0F) is ordinary after a visible scalar, as in an emoji, and a hazard at the start
    /// of the text, after another selector or after a hazard: a run of selectors is how text is smuggled past a reader.
    @inline(__always)
    public static func isHazard(_ scalar: Unicode.Scalar, after previous: Unicode.Scalar?) -> Bool {
        if isHazard(scalar) { return true }
        guard scalar.value == 0xFE0E || scalar.value == 0xFE0F else { return false }
        guard let previous else { return true }
        return isVariationSelector(previous) || isHazard(previous)
    }

    @inline(__always)
    static func isVariationSelector(_ scalar: Unicode.Scalar) -> Bool {
        (0xFE00...0xFE0F).contains(scalar.value) || (0xE0100...0xE01EF).contains(scalar.value)
    }

    /// `text` cut to `cap` characters and about `cap` scalars, plus `…(+N)` naming how many characters were left out
    /// (scalars, when one character holds more than `graphemeOverrun` scalars past the cap and is cut inside); unchanged when it fits.
    public static func capped(_ text: String, cap: Int = maxCharacters) -> String {
        guard text.utf8.count > cap else { return text }
        let scalars = text.unicodeScalars
        var end = text.startIndex
        var characters = 0
        var scalarCount = 0
        while characters < cap, end < text.endIndex {
            let next = text.index(after: end)
            let width = scalars.distance(from: end, to: next)
            if scalarCount + width > cap {
                guard scalarCount + width <= cap + graphemeOverrun else {
                    let cut = scalars.index(end, offsetBy: cap - scalarCount)
                    var shown = ""
                    shown.unicodeScalars.append(contentsOf: scalars[..<cut])
                    return shown + "…(+\(scalars[cut...].count))"
                }
                end = next
                break
            }
            end = next
            characters += 1
            scalarCount += width
        }
        guard end < text.endIndex else { return text }
        return String(text[..<end]) + "…(+\(text[end...].count))"
    }

    /// One line: hazards escaped (a newline shows as `\n`), a tab kept when `keepsTab`, colour (SGR) sequences kept when `keepsSGR`.
    public static func line(_ text: String, cap: Int? = maxCharacters, keepsTab: Bool = true, keepsSGR: Bool = false) -> String {
        let shown = cap.map { capped(text, cap: $0) } ?? text
        if isClean(shown, keepsTab: keepsTab, keepsNewline: false) { return shown }
        var output = ""
        output.reserveCapacity(shown.utf8.count + 16)
        let scalars = shown.unicodeScalars
        var index = scalars.startIndex
        var previous: Unicode.Scalar?
        while index < scalars.endIndex {
            let scalar = scalars[index]
            if keepsSGR, scalar == "\u{1B}", let end = sgrEnd(scalars, from: index) {
                output.unicodeScalars.append(contentsOf: scalars[index..<end])
                index = end
                previous = nil
                continue
            }
            if (keepsTab && scalar == "\t") || !isHazard(scalar, after: previous) {
                output.unicodeScalars.append(scalar)
            } else {
                appendEscape(scalar, to: &output)
            }
            previous = scalar
            scalars.formIndex(after: &index)
        }
        return output
    }

    /// Several lines, each made safe with `line` and uncapped; a continuation line that does not already start with
    /// a space or tab gets `indent`, so text inside a message can never start a line of its own.
    public static func block(_ text: String, indent: String = "  ") -> String {
        if isClean(text, keepsTab: true, keepsNewline: false) { return text }
        var body = Substring(text)
        while body.hasSuffix("\n") { body = body.dropLast() }
        return body.split(separator: "\n", omittingEmptySubsequences: false).enumerated().map { index, piece in
            let shown = line(String(piece), cap: nil)
            guard index > 0, !shown.isEmpty, !shown.hasPrefix(" "), !shown.hasPrefix("\t") else { return shown }
            return indent + shown
        }.joined(separator: "\n")
    }

    /// JSON-quoted and capped: `"Sign in"`.
    public static func quoted(_ text: String, cap: Int? = maxCharacters) -> String {
        var output = ""
        OrderedJSON.writeString(cap.map { capped(text, cap: $0) } ?? text, to: &output)
        return output
    }

    /// Capped and bare when it holds no hazard, else quoted, so a clean name prints as it always did.
    public static func bareOrQuoted(_ text: String, cap: Int? = maxCharacters) -> String {
        isClean(text, keepsTab: false, keepsNewline: false) ? (cap.map { capped(text, cap: $0) } ?? text) : quoted(text, cap: cap)
    }

    /// True when no scalar needs escaping; scans bytes and only decodes scalars once it meets a non-ASCII byte.
    @inline(__always)
    static func isClean(_ text: String, keepsTab: Bool, keepsNewline: Bool) -> Bool {
        for byte in text.utf8 {
            if byte >= 0x20, byte < 0x7F { continue }
            if byte >= 0x80 {
                var previous: Unicode.Scalar?
                for scalar in text.unicodeScalars {
                    defer { previous = scalar }
                    if isHazard(scalar, after: previous), !(keepsTab && scalar == "\t"), !(keepsNewline && scalar == "\n") { return false }
                }
                return true
            }
            if keepsTab, byte == 0x09 { continue }
            if keepsNewline, byte == 0x0A { continue }
            return false
        }
        return true
    }

    /// True when JSON can carry `text` between quotes as it is: no quote, backslash or hazard.
    @inline(__always)
    static func isJSONClean(_ text: String) -> Bool {
        for byte in text.utf8 {
            if byte >= 0x20, byte < 0x7F, byte != 0x22, byte != 0x5C { continue }
            if byte >= 0x80 {
                var previous: Unicode.Scalar?
                for scalar in text.unicodeScalars {
                    defer { previous = scalar }
                    if scalar == "\"" || scalar == "\\" || isHazard(scalar, after: previous) { return false }
                }
                return true
            }
            return false
        }
        return true
    }

    /// `\n`, `\r`, `\t`, `\b`, `\f`, else `\uXXXX` (a surrogate pair above the BMP), as JSON writes them.
    static func appendEscape(_ scalar: Unicode.Scalar, to output: inout String) {
        switch scalar {
        case "\n": output += "\\n"
        case "\r": output += "\\r"
        case "\t": output += "\\t"
        case "\u{08}": output += "\\b"
        case "\u{0C}": output += "\\f"
        default:
            for unit in String(scalar).utf16 {
                output += "\\u"
                for shift in stride(from: 12, through: 0, by: -4) {
                    output.unicodeScalars.append(hexDigits[Int((unit >> UInt16(shift)) & 0xF)])
                }
            }
        }
    }

    private static let hexDigits: [Unicode.Scalar] = Array("0123456789abcdef".unicodeScalars)

    /// The end of an SGR sequence (`ESC [ digits ; m`) starting at `start`, or nil when it is anything else.
    private static func sgrEnd(_ scalars: String.UnicodeScalarView, from start: String.UnicodeScalarView.Index) -> String.UnicodeScalarView.Index? {
        var index = scalars.index(after: start)
        guard index < scalars.endIndex, scalars[index] == "[" else { return nil }
        scalars.formIndex(after: &index)
        while index < scalars.endIndex {
            let scalar = scalars[index]
            if scalar == "m" { return scalars.index(after: index) }
            guard ("0"..."9").contains(scalar) || scalar == ";" || scalar == ":" else { return nil }
            scalars.formIndex(after: &index)
        }
        return nil
    }
}
