import Foundation

/// Keeps a `type` step's text out of batch records and errors: the agent wrote the step, so it already knows it.
public enum BatchStepRedaction {
    public static let marker = "<redacted>"

    /// A `type` line with its text as `<N characters>` and every flag kept; other lines unchanged.
    public static func redactedLine(_ line: String, tokens: [String]?) -> String {
        guard let tokens else {
            return isTypeLine(line) ? "type <unparsed>" : line
        }
        guard tokens.first == "type" else { return line }
        let positionals = textTokens(tokens)
        var output = ["type"]
        var insertedCount = false
        var index = 1
        var afterTerminator = false
        while index < tokens.count {
            let token = tokens[index]
            if !afterTerminator, token == "--" {
                afterTerminator = true
            } else if !afterTerminator, token == "--file", index + 1 < tokens.count {
                output += [token, tokens[index + 1]]
                index += 1
            } else if !afterTerminator, token.hasPrefix("-") {
                output.append(token)
            } else if !insertedCount {
                output.append(characterCount(positionals.joined(separator: " ")))
                insertedCount = true
            }
            index += 1
        }
        return output.joined(separator: " ")
    }

    /// The tokens of a `type` step that are text rather than flags.
    public static func textTokens(_ tokens: [String]) -> [String] {
        guard tokens.first == "type" else { return [] }
        var result: [String] = []
        var index = 1
        var afterTerminator = false
        while index < tokens.count {
            let token = tokens[index]
            if !afterTerminator, token == "--" {
                afterTerminator = true
            } else if !afterTerminator, token == "--file" {
                index += 1
            } else if afterTerminator || !token.hasPrefix("-") {
                result.append(token)
            }
            index += 1
        }
        return result
    }

    /// Replaces each secret (longest first) with the marker, so a parse error cannot echo a step's text.
    public static func scrub(_ message: String, removing secrets: [String]) -> String {
        secrets.filter { !$0.isEmpty }.sorted { $0.count > $1.count }.reduce(message) { text, secret in
            text.replacingOccurrences(of: secret, with: marker)
        }
    }

    public static func isTypeLine(_ line: String) -> Bool {
        line == "type" || line.hasPrefix("type ") || line.hasPrefix("type\t")
    }

    private static func characterCount(_ text: String) -> String {
        let count = text.precomposedStringWithCanonicalMapping.count
        return "<\(count) character\(count == 1 ? "" : "s")>"
    }
}
