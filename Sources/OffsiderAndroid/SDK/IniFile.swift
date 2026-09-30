import Foundation

/// `key=value` lines as the SDK writes them for AVDs and running emulators.
enum IniFile {
    /// Trims keys and values, ignores blank lines and `#` or `;` comments; the last duplicate key wins.
    static func parse(_ text: String) -> [String: String] {
        var values: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#"), !trimmed.hasPrefix(";"),
                  let equals = trimmed.firstIndex(of: "=") else { continue }
            let key = trimmed[..<equals].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            values[key] = trimmed[trimmed.index(after: equals)...].trimmingCharacters(in: .whitespaces)
        }
        return values
    }
}
