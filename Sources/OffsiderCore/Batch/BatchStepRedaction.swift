import Foundation

/// Keeps a `type` step's text out of batch records and errors: the agent wrote the step, so it already knows it.
public enum BatchStepRedaction {
    public static let marker = "<redacted>"

    /// `type`'s flags; a test checks these and `valueOptions` against its help.
    public static let flags: Set<String> = ["--stdin", "--replace", "--verify", "--verify-ignore-text", "--json", "--help", "-h"]
    /// `type`'s options that take a value, kept with their value.
    public static let valueOptions: Set<String> = ["--file", "--verify-timeout", "--verify-id", "--retries", "--into-id", "--into-label", "--require-focus-id", "--device", "--wait-lock"]

    /// A `type` line with its text as `<N characters>` and every option kept; other lines unchanged.
    public static func redactedLine(_ line: String, tokens: [String]?) -> String {
        guard let tokens else {
            return isTypeLine(line) ? "type <unparsed>" : line
        }
        guard tokens.first == "type" else { return line }
        var output = ["type"]
        var text: [String] = []
        var countIndex: Int?
        classify(tokens) { token, isText in
            if isText {
                text.append(token)
                if countIndex == nil {
                    countIndex = output.count
                    output.append("")
                }
            } else {
                output.append(token)
            }
        }
        if let countIndex {
            output[countIndex] = characterCount(text.joined(separator: " "))
        }
        return output.joined(separator: " ")
    }

    /// The tokens of a `type` step that are text rather than options or their values.
    public static func textTokens(_ tokens: [String]) -> [String] {
        guard tokens.first == "type" else { return [] }
        var result: [String] = []
        classify(tokens) { token, isText in
            if isText { result.append(token) }
        }
        return result
    }

    /// Calls `visit` for each token after `type`, saying whether it is text; `--` is kept as an option.
    private static func classify(_ tokens: [String], visit: (String, Bool) -> Void) {
        var index = 1
        var afterTerminator = false
        while index < tokens.count {
            let token = tokens[index]
            if afterTerminator {
                visit(token, true)
            } else if token == "--" {
                afterTerminator = true
                visit(token, false)
            } else if flags.contains(token) || valueOptions.contains(where: { token.hasPrefix($0 + "=") }) {
                visit(token, false)
            } else if valueOptions.contains(token) {
                visit(token, false)
                if index + 1 < tokens.count {
                    index += 1
                    visit(tokens[index], false)
                }
            } else {
                visit(token, true)
            }
            index += 1
        }
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
