import Foundation

/// The permission rules `offsider init` adds to the agents installed on this Mac, so a misled agent cannot run
/// the person-only commands and must ask before the ones that sign in, change permissions or reach a device directly.
public enum AgentPermissionRules {
    public enum Decision: String, Sendable, CaseIterable {
        case deny
        case ask

        var codex: String { self == .deny ? "forbidden" : "prompt" }
    }

    public struct Rule: Equatable, Sendable {
        /// The command as Claude Code's `Bash(...)` pattern sees it.
        public let claude: String
        /// The same command as a Codex `prefix_rule` pattern: argv words matched from the start.
        public let codex: [String]
        public let decision: Decision
        public let reason: String

        public var claudePattern: String { "Bash(\(claude))" }

        public var codexRule: String {
            let pattern = codex.map { "\"\($0)\"" }.joined(separator: ", ")
            return "prefix_rule(pattern=[\(pattern)], decision=\"\(decision.codex)\", justification=\"\(reason)\")"
        }

        /// The part of `codexRule` a person is unlikely to edit, so a reworded justification still counts as present.
        var codexKey: String {
            "prefix_rule(pattern=[\(codex.map { "\"\($0)\"" }.joined(separator: ", "))], decision=\"\(decision.codex)\""
        }
    }

    /// Sorted by pattern within each decision. Claude Code checks deny, then ask, then allow; the first match wins.
    public static let rules: [Rule] = [
        Rule(claude: "offsider credential join*", codex: ["offsider", "credential", "join"], decision: .deny,
             reason: "Links saved test passwords between apps; a person runs it."),
        Rule(claude: "offsider describe-ui --raw-source*", codex: ["offsider", "describe-ui", "--raw-source"], decision: .deny,
             reason: "Dumps the unfiltered tree, secure fields included."),
        Rule(claude: "offsider devices add*", codex: ["offsider", "devices", "add"], decision: .deny,
             reason: "Allows physical devices; a person runs it."),
        Rule(claude: "offsider runner build --register-device*", codex: ["offsider", "runner", "build", "--register-device"], decision: .deny,
             reason: "Registers a device with a signing team; a person runs it."),
        Rule(claude: "offsider unlock-code*", codex: ["offsider", "unlock-code"], decision: .deny,
             reason: "Saves the device unlock code; a person runs it."),
        Rule(claude: "offsider wake --unlock*", codex: ["offsider", "wake", "--unlock"], decision: .deny,
             reason: "Types the saved unlock code into a device."),
        Rule(claude: "adb *", codex: ["adb"], decision: .ask,
             reason: "Raw adb reaches any attached phone without Offsider's checks."),
        Rule(claude: "devicectl *", codex: ["devicectl"], decision: .ask,
             reason: "Raw devicectl reaches any attached iPhone without Offsider's checks."),
        Rule(claude: "offsider batch --no-mask-secure*", codex: ["offsider", "batch", "--no-mask-secure"], decision: .ask,
             reason: "Captures password fields unmasked."),
        Rule(claude: "offsider credential add*", codex: ["offsider", "credential", "add"], decision: .ask,
             reason: "Saves a test password."),
        Rule(claude: "offsider credential describe*", codex: ["offsider", "credential", "describe"], decision: .ask,
             reason: "Changes what a saved test login is for."),
        Rule(claude: "offsider credential remove*", codex: ["offsider", "credential", "remove"], decision: .ask,
             reason: "Removes a saved test password."),
        Rule(claude: "offsider credential set*", codex: ["offsider", "credential", "set"], decision: .ask,
             reason: "Saves a test password."),
        Rule(claude: "offsider credential signed-out*", codex: ["offsider", "credential", "signed-out"], decision: .ask,
             reason: "Clears the record of who is signed in."),
        Rule(claude: "offsider login*", codex: ["offsider", "login"], decision: .ask,
             reason: "Signs in with a saved test password."),
        Rule(claude: "offsider permission*", codex: ["offsider", "permission"], decision: .ask,
             reason: "Grants or revokes app permissions that outlive the command."),
        Rule(claude: "offsider screenshot --no-mask-secure*", codex: ["offsider", "screenshot", "--no-mask-secure"], decision: .ask,
             reason: "Captures password fields unmasked."),
        Rule(claude: "offsider type --file*", codex: ["offsider", "type", "--file"], decision: .ask,
             reason: "Types a file's contents, which may hold a secret."),
        Rule(claude: "xcrun devicectl *", codex: ["xcrun", "devicectl"], decision: .ask,
             reason: "Raw devicectl reaches any attached iPhone without Offsider's checks."),
    ]

    public static func patterns(_ decision: Decision) -> [String] {
        rules.filter { $0.decision == decision }.map(\.claudePattern)
    }

    /// Offsider's earlier rules: where init put one, the narrower rules replace it; moved elsewhere, it is the person's choice.
    static let replacedRules: [Rule] = [
        Rule(claude: "offsider credential*", codex: ["offsider", "credential"], decision: .ask,
             reason: "Saves, shares or removes test passwords."),
    ]

    /// `offsider credential` for `Bash(offsider credential*)`, `Bash(offsider credential:*)` or `Bash(offsider credential *)`; nil for an exact command.
    static func commandPrefix(_ pattern: String) -> String? {
        guard pattern.hasPrefix("Bash("), pattern.hasSuffix("*)") else { return nil }
        var body = pattern.dropFirst(5).dropLast(2)
        if body.hasSuffix(":") { body = body.dropLast() }
        let prefix = body.trimmingCharacters(in: .whitespaces)
        return prefix.isEmpty ? nil : prefix
    }

    /// True when the person's lists decide `rule`: its own pattern anywhere, a covering rule at least as strict, or a `moved` earlier rule.
    static func isDecided(_ rule: Rule, lists: [String: [String]], moved: [Rule]) -> Bool {
        if lists.values.contains(where: { $0.contains(rule.claudePattern) }) { return true }
        guard let wanted = commandPrefix(rule.claudePattern) else { return false }
        let covers = { (pattern: String) in commandPrefix(pattern).map { wanted.hasPrefix($0) } ?? false }
        let strict = rule.decision == .deny ? ["deny"] : ["deny", "ask"]
        if strict.flatMap({ lists[$0] ?? [] }).contains(where: covers) { return true }
        return moved.contains { $0.decision == rule.decision && covers($0.claudePattern) }
    }

    // MARK: Agents

    public enum Agent: String, Sendable, CaseIterable {
        case claudeCode = "claude"
        case codex

        public var name: String { self == .claudeCode ? "Claude Code" : "Codex" }

        /// The folder whose presence means the agent is installed; Offsider never creates it.
        public var root: String { self == .claudeCode ? ".claude" : ".codex" }

        /// Where the rules go, relative to the home folder: Claude Code's user settings, or a Codex rules file Offsider owns.
        public var rulesFile: String { self == .claudeCode ? ".claude/settings.json" : ".codex/rules/offsider.rules" }

        public var pickerRow: [String] { ["Permission rules for \(name)", AgentPermissionRules.pickerDetail] }
    }

    public static let pickerDetail = "deny join, unlock, device access; ask login, permission"
    public static let maxFileBytes = 1 << 20

    /// The agents whose folder exists under `home`, in a stable order.
    public static func detect(home: String, isDirectory: (String) -> Bool = defaultIsDirectory) -> [Agent] {
        Agent.allCases.filter { isDirectory(home + "/" + $0.root) }
    }

    public static func defaultIsDirectory(_ path: String) -> Bool {
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &directory) && directory.boolValue
    }

    // MARK: Merging

    public enum MergeError: Error, Equatable {
        case tooLarge
        case malformed(String)
    }

    public struct Merge: Equatable, Sendable {
        /// The new file content, or nil when every rule is already there and the file stays as it is.
        public let content: Data?
        public let added: Int
        /// Earlier Offsider rules taken out for the narrower ones that replaced them.
        public var replaced = 0
    }

    public static func merge(_ agent: Agent, existing: Data?) throws -> Merge {
        if let existing, existing.count > maxFileBytes { throw MergeError.tooLarge }
        switch agent {
        case .claudeCode: return try mergeClaudeSettings(existing)
        case .codex: return try mergeCodexRules(existing)
        }
    }

    /// Adds the missing patterns to `permissions.deny` and `permissions.ask`, keeping every other key and value in order.
    /// A pattern the person already placed in `allow`, `ask` or `deny` is their choice and is left where it is.
    static func mergeClaudeSettings(_ existing: Data?) throws -> Merge {
        var root: [(String, OrderedJSON)] = []
        if let existing, !isBlank(existing) {
            let parsed: OrderedJSON
            do {
                parsed = try OrderedJSON.parse(existing)
            } catch {
                throw MergeError.malformed("is not valid JSON")
            }
            guard case .object(let members) = parsed else { throw MergeError.malformed("is not a JSON object") }
            root = members
        }
        var permissions: [(String, OrderedJSON)] = []
        let permissionsIndex = root.firstIndex { $0.0 == "permissions" }
        if let permissionsIndex {
            guard case .object(let members) = root[permissionsIndex].1 else { throw MergeError.malformed("has a permissions value that is not an object") }
            permissions = members
        }
        var lists: [String: [String]] = [:]
        for (key, value) in permissions where ["allow", "ask", "deny"].contains(key) {
            guard case .array(let entries) = value else { throw MergeError.malformed("has a permissions.\(key) value that is not a list") }
            lists[key] = entries.compactMap { if case .string(let pattern) = $0 { return pattern } else { return nil } }
        }
        let outdated = replacedRules.filter { lists[$0.decision.rawValue]?.contains($0.claudePattern) == true }
        let moved = replacedRules.filter { old in !outdated.contains(old) && lists.values.contains { $0.contains(old.claudePattern) } }
        for old in outdated {
            guard let index = permissions.firstIndex(where: { $0.0 == old.decision.rawValue }), case .array(let entries) = permissions[index].1 else { continue }
            permissions[index].1 = .array(entries.filter { if case .string(old.claudePattern) = $0 { return false } else { return true } })
            lists[old.decision.rawValue]?.removeAll { $0 == old.claudePattern }
        }
        let replaced = outdated.count
        var added = 0
        for decision in Decision.allCases {
            let missing = rules.filter { $0.decision == decision && !isDecided($0, lists: lists, moved: moved) }.map(\.claudePattern)
            guard !missing.isEmpty else { continue }
            added += missing.count
            if let index = permissions.firstIndex(where: { $0.0 == decision.rawValue }), case .array(let entries) = permissions[index].1 {
                permissions[index].1 = .array(entries + missing.map(OrderedJSON.string))
            } else {
                permissions.append((decision.rawValue, .array(missing.map(OrderedJSON.string))))
            }
        }
        guard added + replaced > 0 else { return Merge(content: nil, added: 0) }
        if let permissionsIndex {
            root[permissionsIndex].1 = .object(permissions)
        } else {
            root.append(("permissions", .object(permissions)))
        }
        return Merge(content: Data((OrderedJSON.object(root).rendered() + "\n").utf8), added: added, replaced: replaced)
    }

    public static let codexHeader = "# Offsider's permission rules for Codex, from offsider init. Edit freely: init only adds missing rules.\n"

    /// Appends the missing `prefix_rule` lines to Offsider's own Codex rules file and takes out earlier ones they replace.
    static func mergeCodexRules(_ existing: Data?) throws -> Merge {
        var text = ""
        if let existing {
            guard let decoded = String(validating: existing, as: UTF8.self) else { throw MergeError.malformed("is not UTF-8 text") }
            text = decoded
        }
        let outdated = replacedRules.filter { text.contains($0.codexKey) }
        for old in outdated {
            text = text.split(separator: "\n", omittingEmptySubsequences: false).filter { !$0.contains(old.codexKey) }.joined(separator: "\n")
        }
        let lines = codexPrefixRules(text)
        let moved = replacedRules.filter { old in !outdated.contains(old) && lines.contains { $0.words == old.codex } }
        let missing = rules.filter { !text.contains($0.codexKey) && !isDecided($0, codex: lines, moved: moved) }
        guard !missing.isEmpty || !outdated.isEmpty else { return Merge(content: nil, added: 0) }
        if text.isEmpty {
            text = codexHeader
        } else if !text.hasSuffix("\n") {
            text += "\n"
        }
        text += missing.map { $0.codexRule + "\n" }.joined()
        return Merge(content: Data(text.utf8), added: missing.count, replaced: outdated.count)
    }

    /// Each `prefix_rule` line's plain words and decision; a comment or a line with a list of alternatives is left out.
    static func codexPrefixRules(_ text: String) -> [(words: [String], decision: String)] {
        text.split(separator: "\n").compactMap { line in
            guard let match = line.prefixMatch(of: #/\s*prefix_rule\(pattern=\[([^\[\]]*)\], decision="([a-z]+)"/#) else { return nil }
            let words = match.1.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            guard words.allSatisfy({ $0.count >= 2 && $0.hasPrefix("\"") && $0.hasSuffix("\"") }) else { return nil }
            return (words.map { String($0.dropFirst().dropLast()) }, String(match.2))
        }
    }

    /// `isDecided` for Codex: a covering line that prompts or forbids at least as much, or a `moved` earlier rule.
    static func isDecided(_ rule: Rule, codex lines: [(words: [String], decision: String)], moved: [Rule]) -> Bool {
        let strict = rule.decision == .deny ? ["forbidden"] : ["forbidden", "prompt"]
        if lines.contains(where: { strict.contains($0.decision) && rule.codex.starts(with: $0.words) }) { return true }
        return moved.contains { $0.decision == rule.decision && rule.codex.starts(with: $0.codex) }
    }

    private static func isBlank(_ data: Data) -> Bool {
        data.allSatisfy { [0x20, 0x09, 0x0A, 0x0D].contains($0) }
    }

    // MARK: Output

    /// `init --print-rules`: both agents' rules, ready to apply by hand, with the reason for each.
    public static func printedJSON() -> String {
        let claude = OrderedJSON.object([
            ("file", .string("~/" + Agent.claudeCode.rulesFile)),
            ("permissions", .object(Decision.allCases.map { ($0.rawValue, .array(patterns($0).map(OrderedJSON.string))) })),
        ])
        let codex = OrderedJSON.object([
            ("file", .string("~/" + Agent.codex.rulesFile)),
            ("rules", .array(rules.map { .string($0.codexRule) })),
        ])
        let reasons = OrderedJSON.array(rules.map { rule in
            .object([
                ("command", .string(rule.codex.joined(separator: " "))),
                ("decision", .string(rule.decision.rawValue)),
                ("reason", .string(rule.reason)),
            ])
        })
        return OrderedJSON.object([("claude", claude), ("codex", codex), ("rules", reasons)]).rendered() + "\n"
    }

    /// `Rules added to ~/.claude/settings.json (15 new)`, `Rules updated in ...` or `Rules already present in ...`.
    public static func resultLine(path: String, added: Int, replaced: Int = 0) -> String {
        let note = replaced == 0 ? "" : ", \(replaced) older replaced"
        if added == 0 {
            return replaced == 0 ? "Rules already present in \(path)" : "Rules updated in \(path) (\(replaced) older replaced)"
        }
        return "Rules added to \(path) (\(added) new\(note))"
    }

    public static func failureLine(path: String, error: MergeError) -> String {
        let problem: String
        switch error {
        case .tooLarge: problem = "is over 1 MiB"
        case .malformed(let detail): problem = detail
        }
        return "\(path) \(problem), so it was left as is. Fix it, then run offsider init --rules-only."
    }

    /// `install.rules`: every installed agent has every rule; `lacking` names the agents that do not, `outdated` those holding a rule since replaced.
    public static func doctorVerdict(detected: [Agent], lacking: [Agent], outdated: [Agent] = []) -> DoctorRules.Verdict {
        if detected.isEmpty {
            return (.skip, "No Claude Code or Codex folder found", nil)
        }
        if !lacking.isEmpty {
            return (.warn, "\(lacking.map(\.name).joined(separator: " and ")) \(lacking.count == 1 ? "lacks" : "lack") Offsider's permission rules", "Run offsider init --rules-only.")
        }
        if !outdated.isEmpty {
            return (.warn, "\(outdated.map(\.name).joined(separator: " and ")) \(outdated.count == 1 ? "has" : "have") an older Offsider rule to replace", "Run offsider init --rules-only.")
        }
        return (.pass, "\(detected.map(\.name).joined(separator: " and ")) \(detected.count == 1 ? "has" : "have") Offsider's permission rules", nil)
    }
}
