import Foundation

/// What `init` prints: a person sees a row per skill folder and rules file, then a ✅ closing and the next command;
/// an agent or a pipe keeps the plain `Installed Offsider skill -> Client: path` lines.
public enum InitScreen {
    public static let agentsQuestion = "Which agents?"
    public static let cancelled = "👋 Cancelled, nothing installed."

    /// One thing `init` did to a skill folder or an agent's rules file, with the line an agent reads for it.
    public struct Step: Equatable, Sendable {
        public enum Kind: Equatable, Sendable {
            case installed, updated, upToDate, removed
            case rulesAdded(Int)
            case rulesPresent
        }

        public var kind: Kind
        /// The clients sharing a skills folder, or the agent the rules are for.
        public var who: String
        public var path: String
        public var line: String

        public init(_ kind: Kind, who: String, path: String, line: String) {
            self.kind = kind
            self.who = who
            self.path = path
            self.line = line
        }

        fileprivate var changed: Bool { kind != .upToDate && kind != .rulesPresent }

        fileprivate var what: String {
            switch kind {
            case .rulesAdded, .rulesPresent: return "Rules"
            default: return "Skill"
            }
        }

        fileprivate var state: String {
            switch kind {
            case .installed: return "installed"
            case .updated: return "updated"
            case .upToDate, .rulesPresent: return "up to date"
            case .removed: return "removed"
            case .rulesAdded(let count): return count == 0 ? "updated" : "\(count) new"
            }
        }
    }

    /// The steps as rows and a closing; with `next`, a person's next command and an agent's `Next:` line.
    public static func page(_ steps: [Step], next: String? = nil, home: String = NSHomeDirectory()) -> Page {
        let agent = (steps.map(\.line) + (next.map { ["Next: \($0)"] } ?? [])).map { $0 + "\n" }.joined()
        let table = Table(columns: [
            Table.Column(agent: nil, person: 0, fit: .whole),
            Table.Column(agent: nil, person: 1, fit: .cut(min: 8)),
            Table.Column(agent: nil, person: 2, fit: .cut(min: 16, at: .middle), tone: .dim),
        ], rows: steps.map { step in
            Table.Row([Table.Cell(step.what), Table.Cell(step.who), Table.Cell(TerminalText.homePath(step.path, home: home), tag: step.state)], status: step.changed ? .ok : .skip)
        })
        let headline: String
        if steps.allSatisfy({ $0.kind == .removed }) {
            headline = "Offsider skill removed"
        } else if steps.contains(where: \.changed) {
            headline = "Ready for your agents"
        } else {
            headline = "Already up to date"
        }
        return Page([.person([.table(table), .outcome(.done(headline))]), .agent(agent)], notices: next.map { [.next($0)] } ?? [])
    }

    /// `init --uninstall` with nothing installed.
    public static let nothingToRemove = Page([
        .person([.outcome(.done("Nothing to remove", details: ["No Offsider skill was installed"]))]),
        .agent("No installed Offsider skill directories were found.\n"),
    ])
}
