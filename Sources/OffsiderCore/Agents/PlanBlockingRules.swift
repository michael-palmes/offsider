import Foundation

/// `doctor`'s `install.deny-rules`: an agent deny rule that also blocks `offsider devices add --plan`, the read-only way an agent gets the one command a person runs.
public enum PlanBlockingRules {
    /// The plan as an agent runs it, with and without `--json`.
    public static let planCommands = ["offsider devices add --plan --json", "offsider devices add --plan"]
    static let planWords = ["offsider", "devices", "add", "--plan", "--json"]

    public enum Source: Equatable, Sendable {
        case claudeSettings
        case codexRules
    }

    public struct Finding: Equatable, Sendable {
        /// As shown, such as `~/.claude/settings.json`.
        public let file: String
        /// As written in the file.
        public let rule: String

        public init(file: String, rule: String) {
            self.file = file
            self.rule = rule
        }
    }

    // MARK: Files

    /// A `.git` entry: a repository's folder, or a worktree's file naming its `gitdir:`.
    public enum GitEntry: Equatable, Sendable {
        case directory
        case file(String)
    }

    /// Claude Code's user files, then the project files under `directory`, its repository root and a worktree's main checkout, then Codex's Offsider rules.
    public static func files(home: String, directory: String, gitEntry: (String) -> GitEntry?) -> [(source: Source, path: String)] {
        var roots = [directory]
        if let repository = repositoryRoots(from: directory, gitEntry: gitEntry) {
            roots += [repository.checkout] + (repository.main.map { [$0] } ?? [])
        }
        let claude = [home] + roots
        var seen = Set<String>()
        let paths = claude.flatMap { [$0 + "/.claude/settings.json", $0 + "/.claude/settings.local.json"] }
            .map { ($0 as NSString).standardizingPath }
            .filter { seen.insert($0).inserted }
        return paths.map { (Source.claudeSettings, $0) } + [(.codexRules, home + "/" + AgentPermissionRules.Agent.codex.rulesFile)]
    }

    /// The nearest folder holding `.git`, and for a worktree the main checkout its `gitdir:` points into.
    static func repositoryRoots(from directory: String, gitEntry: (String) -> GitEntry?) -> (checkout: String, main: String?)? {
        guard let root = GitWorkTree.root(containing: directory, exists: { gitEntry($0) != nil }) else { return nil }
        guard case .file(let text)? = gitEntry(root + "/.git") else { return (root, nil) }
        return (root, mainCheckout(gitFile: text, in: root))
    }

    /// `gitdir: /repo/.git/worktrees/name` gives `/repo`; a relative `gitdir:` is read from `folder`.
    static func mainCheckout(gitFile text: String, in folder: String) -> String? {
        guard let line = text.split(whereSeparator: \.isNewline).first, line.hasPrefix("gitdir:") else { return nil }
        var target = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
        if !target.hasPrefix("/") { target = folder + "/" + target }
        let standard = (target as NSString).standardizingPath
        guard let marker = standard.range(of: "/.git/worktrees/") else { return nil }
        return String(standard[..<marker.lowerBound])
    }

    // MARK: Rules

    /// Every `permissions.deny` string in a Claude Code settings file; none when it is not a JSON object.
    static func claudeDenyRules(_ data: Data) -> [String] {
        guard let parsed = try? OrderedJSON.parse(data), case .object(let root) = parsed,
              case .object(let permissions)? = root.first(where: { $0.0 == "permissions" })?.1,
              case .array(let entries)? = permissions.first(where: { $0.0 == "deny" })?.1 else {
            return []
        }
        return entries.compactMap { if case .string(let rule) = $0 { return rule } else { return nil } }
    }

    /// Claude Code's documented `Bash(...)` matching; a rule that matches every command (`Bash(*)`) is not about Offsider, so it never counts.
    static func claudeMatches(_ rule: String, command: String) -> Bool {
        guard rule.hasPrefix("Bash("), rule.hasSuffix(")") else { return false }
        var pattern = String(rule.dropFirst(5).dropLast())
        if pattern.hasSuffix(":*") { pattern = String(pattern.dropLast(2)) + " *" }
        guard pattern.contains(where: { $0 != "*" && $0 != " " }) else { return false }
        guard pattern.contains("*") else { return pattern == command }
        if pattern.hasSuffix(" *"), pattern.filter({ $0 == "*" }).count == 1, command == String(pattern.dropLast(2)) { return true }
        return wildcard(pattern, matches: command)
    }

    /// `*` stands for any text, spaces included; every other character matches itself.
    static func wildcard(_ pattern: String, matches text: String) -> Bool {
        let pattern = Array(pattern.unicodeScalars)
        let text = Array(text.unicodeScalars)
        var (p, t, star, resume) = (0, 0, -1, 0)
        while t < text.count {
            if p < pattern.count, pattern[p] == "*" {
                (star, resume, p) = (p, t, p + 1)
            } else if p < pattern.count, pattern[p] == text[t] {
                (p, t) = (p + 1, t + 1)
            } else if star >= 0 {
                resume += 1
                (p, t) = (star + 1, resume)
            } else {
                return false
            }
        }
        while p < pattern.count, pattern[p] == "*" { p += 1 }
        return p == pattern.count
    }

    /// Codex `prefix_rule` lines whose words lead the plan's and whose decision is `forbidden`, as written.
    static func codexForbiddenRules(_ data: Data) -> [String] {
        guard let text = String(validating: data, as: UTF8.self) else { return [] }
        return text.split(separator: "\n").compactMap { line in
            guard let rule = AgentPermissionRules.codexPrefixRules(String(line)).first, rule.decision == "forbidden",
                  !rule.words.isEmpty, planWords.starts(with: rule.words) else { return nil }
            return line.trimmingCharacters(in: .whitespaces)
        }
    }

    /// In `initFile`, the settings file `init` writes, a deny rule an earlier `init` put there is left to `install.rules`, whose `init --rules-only` removes it.
    public static func findings(_ files: [(source: Source, shown: String, data: Data)], initFile: String? = nil) -> [Finding] {
        let initOwn = Set(AgentPermissionRules.replacedRules.filter { $0.decision == .deny }.map(\.claudePattern))
        return files.flatMap { file in
            let rules = switch file.source {
            case .claudeSettings:
                claudeDenyRules(file.data).filter { rule in
                    !(file.shown == initFile && initOwn.contains(rule)) && planCommands.contains { claudeMatches(rule, command: $0) }
                }
            case .codexRules: codexForbiddenRules(file.data)
            }
            return rules.map { Finding(file: file.shown, rule: $0) }
        }
    }

    /// Warns naming each file and rule; the fix is a person's, since an agent never loosens a rule.
    public static func verdict(_ findings: [Finding], filesRead: Int, audience: ErrorAudience = .current) -> DoctorRules.Verdict {
        guard filesRead > 0 else { return (.skip, "No Claude Code or Codex settings found", nil) }
        guard !findings.isEmpty else { return (.pass, "No agent rule blocks `offsider devices add --plan`", nil) }
        let shown = findings.prefix(3).map { "\(TerminalText.line($0.file, cap: 200, keepsTab: false)) denies \(TerminalText.quoted($0.rule, cap: 200))" }
        let more = findings.count > 3 ? " and \(findings.count - 3) more" : ""
        let detail = shown.joined(separator: "; ") + more + ", which also blocks the read-only `offsider devices add --plan`, so an agent cannot read the one command a person runs"
        let hint = audience == .person
            ? "Remove \(findings.count == 1 ? "it" : "them") if you like: `devices add` refuses without you at the terminal and Touch ID anyway."
            : "Ask the user to remove \(findings.count == 1 ? "it" : "them"): `devices add` refuses without them at the terminal and Touch ID anyway. Until then, ask them to run `offsider devices add` in their own terminal. Never edit the file yourself."
        return (.warn, detail, hint)
    }
}
