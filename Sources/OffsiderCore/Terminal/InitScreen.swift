import Foundation

/// What `init` prints on a terminal: each `Installed Offsider skill -> Client: path` line as a bold `✅` line with the path dim
/// under it, and `Next: <command>` as a next step. Piped output keeps the plain lines.
public enum InitScreen {
    public static let agentsQuestion = "Which agents?"
    public static let cancelled = "👋 Cancelled, nothing installed."

    /// `path` with the home folder written as `~`.
    public static func shortPath(_ path: String, home: String) -> String {
        path == home || path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    public static func styled(_ lines: [String], style: TerminalStyle) -> [String] {
        lines.flatMap { line -> [String] in
            if line.hasPrefix("Next: ") { return [PromptScreen.nextStep("Next", command: String(line.dropFirst(6)), style: style)] }
            guard let arrow = line.range(of: " -> "), let colon = line.range(of: ": ", range: arrow.upperBound..<line.endIndex) else { return [line] }
            let head = "\(line[..<arrow.lowerBound]) for \(line[arrow.upperBound..<colon.lowerBound])"
            return [style.mark(.done) + " " + style.bold(head), "   " + style.dim(String(line[colon.upperBound...]))]
        }
    }
}
