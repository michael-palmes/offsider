import Foundation

/// The Swift lines under `Sources/`, read once for the source lints.
enum SourceLines {
    struct Line: Sendable {
        /// The path relative to `Sources/`.
        let file: String
        let number: Int
        let text: Substring

        var isComment: Bool { text.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
        var location: String { "\(file):\(number)" }
    }

    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources")

    /// Every line, or nil when a file could not be read, so a lint never passes on an empty tree.
    static let all: [Line]? = {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return nil }
        var lines: [Line] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            guard let data = try? Data(contentsOf: url) else { return nil }
            let file = String(url.path.dropFirst(root.path.count + 1))
            for (index, text) in String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                lines.append(Line(file: file, number: index + 1, text: text))
            }
        }
        return lines.isEmpty ? nil : lines
    }()
}
