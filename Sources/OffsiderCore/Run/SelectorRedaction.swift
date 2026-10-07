import Foundation

/// Keeps mask and grep selectors out of run manifests and batch records, since they often spell the personal data they hide.
public enum SelectorRedaction {
    /// Options whose values become `<N characters>`. `--mask-id` values are the app's own element ids and `--mask-region` values are coordinates, so both stay.
    public static let options: Set<String> = ["--mask-text", "--mask-label", "--grep"]

    /// The tokens with each selector value as `<N characters>`, in `--option value ...` and `--option=value` forms.
    public static func redacted(_ tokens: [String]) -> [String] {
        var result: [String] = []
        var takingValues = false
        for token in tokens {
            if takingValues, !token.hasPrefix("-") {
                result.append(BatchStepRedaction.characterCount(token))
                continue
            }
            takingValues = options.contains(token)
            if let equals = token.firstIndex(of: "="), options.contains(String(token[..<equals])) {
                result.append(String(token[...equals]) + BatchStepRedaction.characterCount(String(token[token.index(after: equals)...])))
            } else {
                result.append(token)
            }
        }
        return result
    }

    /// Whether a line that could not be split into tokens may still hold a selector.
    public static func mentionsSelector(_ line: String) -> Bool {
        options.contains { line.contains($0) }
    }
}
