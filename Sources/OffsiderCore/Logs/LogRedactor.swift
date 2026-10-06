import Foundation

/// Masks passwords, tokens, keys, cookies and emails in log text, keeping the text's shape so JSON still parses.
public enum LogRedactor {
    public static let marker = "[redacted]"
    public static let jwtMarker = "[redacted jwt]"
    public static let emailMarker = "[redacted email]"

    static let sensitiveSegments: Set<String> = [
        "password", "passwd", "passcode", "pwd", "pin", "secret", "token", "authorization", "jwt", "ticket", "email",
        "cookie", "otp", "apikey",
    ]
    static let exemptLastSegments: Set<String> = [
        "id", "ids", "type", "count", "length", "expiry", "expires", "ttl", "verified", "enabled", "required", "valid", "status", "at",
    ]
    /// Keys whose unquoted value is a whole header value, spaces included.
    static let headerKeys: Set<String> = ["authorization", "proxy-authorization", "cookie"]
    static let prefilterWords = ["@", "eyj", "earer", "asic ", "pass", "pwd", "pin", "secret", "token", "auth", "jwt", "ticket", "email", "cookie", "otp", "api"]

    private static let key = try! NSRegularExpression(pattern: #"(["']?)([A-Za-z][A-Za-z0-9_.-]{0,63})\1\s*[:=]\s*"#)
    private static let scheme = try! NSRegularExpression(pattern: #"\b(Bearer|Basic)\s+[A-Za-z0-9._~+/=-]{8,}"#)
    private static let jwt = try! NSRegularExpression(pattern: #"\beyJ[A-Za-z0-9_-]{8,}\.eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]*"#)
    private static let email = try! NSRegularExpression(pattern: PersonalData.emailPattern)

    /// The text with every sensitive value replaced, and how many values were replaced; markers already there are left and not counted.
    public static func redact(_ text: String) -> (text: String, count: Int) {
        let lowered = text.lowercased()
        guard prefilterWords.contains(where: lowered.contains) else { return (text, 0) }
        var count = 0
        var result = redactKeyValues(text, count: &count)
        result = replace(scheme, in: result, template: "$1 \(marker)", count: &count)
        result = replace(jwt, in: result, template: jwtMarker, count: &count)
        result = replace(email, in: result, template: emailMarker, count: &count)
        return (result, count)
    }

    /// Whether a key such as `accessToken`, `refresh_token` or `x-api-key` names a secret; `tokenType` and `emailVerified` do not.
    public static func isSensitive(key: String) -> Bool {
        let segments = self.segments(of: key)
        guard let last = segments.last, !exemptLastSegments.contains(last) else { return false }
        if segments.contains(where: sensitiveSegments.contains) { return true }
        return zip(segments, segments.dropFirst()).contains { $0 == "api" && $1 == "key" }
    }

    /// Lowercased camel, snake, kebab and dot segments: `xAPIKey` is `x`, `api`, `key`.
    static func segments(of key: String) -> [String] {
        var segments: [String] = []
        var current = ""
        let characters = Array(key)
        for (index, character) in characters.enumerated() {
            if character == "_" || character == "-" || character == "." {
                if !current.isEmpty { segments.append(current) }
                current = ""
                continue
            }
            if character.isUppercase, let previous = current.last {
                let nextIsLower = index + 1 < characters.count && characters[index + 1].isLowercase
                if previous.isLowercase || previous.isNumber || (previous.isUppercase && nextIsLower) {
                    segments.append(current)
                    current = ""
                }
            }
            current.append(character)
        }
        if !current.isEmpty { segments.append(current) }
        return segments.map { $0.lowercased() }
    }

    private static func redactKeyValues(_ text: String, count: inout Int) -> String {
        let source = text as NSString
        let output = NSMutableString()
        var cursor = 0
        while cursor < source.length,
              let match = key.firstMatch(in: text, range: NSRange(location: cursor, length: source.length - cursor)) {
            let name = source.substring(with: match.range(at: 2))
            let keyQuoted = match.range(at: 1).length > 0
            let valueStart = match.range.location + match.range.length
            output.append(source.substring(with: NSRange(location: cursor, length: valueStart - cursor)))
            cursor = valueStart
            guard isSensitive(key: name), valueStart < source.length else { continue }

            let first = source.character(at: valueStart)
            if first == 0x22 || first == 0x27 {
                let close = closingQuote(first, in: source, from: valueStart + 1)
                let inner = source.substring(with: NSRange(location: valueStart + 1, length: close - valueStart - 1))
                if !inner.isEmpty, !isMarker(inner) { count += 1 }
                output.append(String(utf16CodeUnits: [first], count: 1))
                output.append(inner.isEmpty || isMarker(inner) ? inner : marker)
                cursor = close
                continue
            }
            let end = headerKeys.contains(name.lowercased()) ? headerValueEnd(in: source, from: valueStart) : plainValueEnd(in: source, from: valueStart)
            let value = source.substring(with: NSRange(location: valueStart, length: end - valueStart))
            guard !value.isEmpty, !["true", "false", "null", "undefined"].contains(value), !value.hasPrefix("{"), !value.hasPrefix("[") else { continue }
            count += 1
            output.append(keyQuoted ? "\"\(marker)\"" : marker)
            cursor = end
        }
        if cursor < source.length {
            output.append(source.substring(from: cursor))
        }
        return output as String
    }

    /// The index of the closing quote, skipping backslash escapes; the end of the text when it never closes.
    private static func closingQuote(_ quote: unichar, in source: NSString, from start: Int) -> Int {
        var index = start
        while index < source.length {
            let character = source.character(at: index)
            if character == 0x5C { index += 2; continue }
            if character == quote { return index }
            index += 1
        }
        return source.length
    }

    /// Up to a quote, a comma followed by a space, or the end of the line.
    private static func headerValueEnd(in source: NSString, from start: Int) -> Int {
        var index = start
        while index < source.length {
            let character = source.character(at: index)
            if character == 0x22 || character == 0x27 || character == 0x0A || character == 0x0D { break }
            if character == 0x2C, index + 1 < source.length, source.character(at: index + 1) == 0x20 { break }
            index += 1
        }
        while index > start, source.character(at: index - 1) == 0x20 { index -= 1 }
        return index
    }

    /// Up to whitespace or one of `,;&}])`.
    private static func plainValueEnd(in source: NSString, from start: Int) -> Int {
        let stops = Set(",;&}])".utf16)
        var index = start
        while index < source.length {
            let character = source.character(at: index)
            if stops.contains(character) || Unicode.Scalar(character).map(CharacterSet.whitespacesAndNewlines.contains) == true { break }
            index += 1
        }
        return index
    }

    private static func isMarker(_ value: String) -> Bool {
        value == marker || value == jwtMarker || value == emailMarker
    }

    private static func replace(_ regex: NSRegularExpression, in text: String, template: String, count: inout Int) -> String {
        let range = NSRange(text.startIndex..., in: text)
        let matches = regex.numberOfMatches(in: text, range: range)
        guard matches > 0 else { return text }
        count += matches
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: template)
    }
}
