import Foundation

/// A repository's `offsider.mask.json`: elements and text every capture, tree and cached tree masks, found the same way as `OFFSIDER.md`.
public struct MaskConfig: Equatable, Sendable {
    public static let fileName = "offsider.mask.json"
    public static let maximumBytes = 64 * 1024
    public static let maximumEntries = 64
    public static let maximumPatternLength = 200

    public var ids: [String]
    public var labels: [String]
    public var labelContains: [String]
    /// Case-insensitive ICU expressions with bounded quantifiers only.
    public var valuePatterns: [String]
    public var emails: Bool

    public init(ids: [String] = [], labels: [String] = [], labelContains: [String] = [], valuePatterns: [String] = [], emails: Bool = false) {
        self.ids = ids
        self.labels = labels
        self.labelContains = labelContains
        self.valuePatterns = valuePatterns
        self.emails = emails
    }

    public var isEmpty: Bool { ids.isEmpty && labels.isEmpty && labelContains.isEmpty && valuePatterns.isEmpty && !emails }

    /// The screenshot masks the file asks for: value patterns paint as `--mask-text` does.
    public var plan: MaskPlan {
        MaskPlan(ids: ids, labels: labels, labelsContaining: labelContains, texts: valuePatterns, emails: emails)
    }

    /// Every `--mask-...` selector the file adds, as `MaskResult.unmatched` names them, so a capture does not warn about them.
    public var selectorNames: Set<String> {
        Set(ids.map { "--mask-id \($0)" } + labels.map { "--mask-label \($0)" } + labelContains.map { "--mask-label-contains \($0)" }
            + valuePatterns.map { "--mask-text \($0)" })
    }

    private static let keys: Set<String> = ["ids", "labels", "labelContains", "valuePatterns", "emails"]

    /// Strict: unknown keys, wrong types, empty or oversized lists and unbounded patterns are refused, naming the line.
    /// Keys starting with `//` are comments and must hold a string.
    public static func parse(_ data: Data, path: String = fileName) throws -> MaskConfig {
        let text = String(decoding: data, as: UTF8.self)
        guard data.count <= maximumBytes else {
            throw MaskConfigError("\(path) is larger than 64 KiB.")
        }
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            let line = (error as NSError).userInfo[NSDebugDescriptionErrorKey].flatMap { lineNumber(in: "\($0)") }
            throw MaskConfigError("\(path)\(line.map { " line \($0)" } ?? "") is not valid JSON.")
        }
        guard let raw = object as? [String: Any] else {
            throw MaskConfigError("\(path) must be a JSON object.")
        }
        func fail(_ key: String, _ message: String) -> MaskConfigError {
            MaskConfigError("\(path) line \(line(of: key, in: text)): \(message)")
        }
        for (key, value) in raw where !keys.contains(key) {
            if key.hasPrefix("//") {
                guard value is String else { throw fail(key, "the comment \(key) must be a string.") }
                continue
            }
            throw fail(key, "unknown key \(key); use ids, labels, labelContains, valuePatterns or emails.")
        }
        func list(_ key: String) throws -> [String] {
            guard let value = raw[key], !(value is NSNull) else { return [] }
            guard let items = value as? [Any], items.allSatisfy({ $0 is String }) else {
                throw fail(key, "\(key) must be a list of strings.")
            }
            let texts = items.compactMap { $0 as? String }
            guard texts.count <= maximumEntries else { throw fail(key, "\(key) has more than \(maximumEntries) entries.") }
            guard !texts.contains(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
                throw fail(key, "\(key) has an empty entry.")
            }
            return texts
        }
        var emails = false
        if let value = raw["emails"], !(value is NSNull) {
            guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
                throw fail("emails", "emails must be true or false.")
            }
            emails = number.boolValue
        }
        let patterns = try list("valuePatterns")
        for pattern in patterns {
            if let problem = patternProblem(pattern) { throw fail("valuePatterns", problem) }
        }
        return MaskConfig(ids: try list("ids"), labels: try list("labels"), labelContains: try list("labelContains"), valuePatterns: patterns, emails: emails)
    }

    /// Why a value pattern is refused: too long, not an ICU expression, or with `*`, `+` or `{n,}`, which can run without bound.
    public static func patternProblem(_ pattern: String) -> String? {
        guard pattern.count <= maximumPatternLength else {
            return "the value pattern \(pattern.prefix(40))… is longer than \(maximumPatternLength) characters."
        }
        guard (try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])) != nil else {
            return "the value pattern \(pattern) is not a valid regular expression; escape ( [ . * with a backslash to match them literally."
        }
        var escaped = false
        var inClass = false
        var openBrace = false
        var sawComma = false
        var digitsAfterComma = false
        for character in pattern {
            if escaped { escaped = false; continue }
            switch character {
            case "\\": escaped = true
            case "[" where !inClass: inClass = true
            case "]" where inClass: inClass = false
            case "*" where !inClass, "+" where !inClass:
                return "the value pattern \(pattern) uses \(character), which has no limit; use a bounded count such as {1,40}."
            case "{" where !inClass:
                openBrace = true
                sawComma = false
                digitsAfterComma = false
            case "," where openBrace:
                sawComma = true
            case "}" where openBrace:
                openBrace = false
                if sawComma, !digitsAfterComma {
                    return "the value pattern \(pattern) uses {n,}, which has no limit; use a bounded count such as {1,40}."
                }
            default:
                if openBrace, sawComma, character.isNumber { digitsAfterComma = true }
            }
        }
        return nil
    }

    /// The 1-based line where `"key"` first appears, else 1.
    static func line(of key: String, in text: String) -> Int {
        guard let range = text.range(of: "\"\(key)\"") else { return 1 }
        return text[..<range.lowerBound].reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
    }

    /// `line 4` out of a JSONSerialization message such as `... around line 4, column 2.`.
    static func lineNumber(in message: String) -> Int? {
        guard let range = message.range(of: "line ") else { return nil }
        return Int(message[range.upperBound...].prefix { $0.isNumber })
    }
}

public struct MaskConfigError: Equatable, Error, Sendable, CustomStringConvertible {
    public var message: String

    public init(_ message: String) {
        self.message = message
    }

    public var description: String { message }
}
