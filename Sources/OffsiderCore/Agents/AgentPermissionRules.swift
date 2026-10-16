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
        Rule(claude: "offsider device-access*", codex: ["offsider", "device-access"], decision: .deny,
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
        Rule(claude: "offsider credential*", codex: ["offsider", "credential"], decision: .ask,
             reason: "Saves, shares or removes test passwords."),
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
    }

    public static func merge(_ agent: Agent, existing: Data?) throws -> Merge {
        if let existing, existing.count > maxFileBytes { throw MergeError.tooLarge }
        switch agent {
        case .claudeCode: return try mergeClaudeSettings(existing)
        case .codex: return try mergeCodexRules(existing)
        }
    }

    /// The rules missing from `existing`; a file that cannot be read as the agent's format counts as missing them all.
    public static func missing(_ agent: Agent, existing: Data?) -> Int {
        guard let merge = try? merge(agent, existing: existing) else { return rules.count }
        return merge.added
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
        var chosen = Set<String>()
        for (key, value) in permissions where ["allow", "ask", "deny"].contains(key) {
            guard case .array(let entries) = value else { throw MergeError.malformed("has a permissions.\(key) value that is not a list") }
            for case .string(let pattern) in entries { chosen.insert(pattern) }
        }
        var added = 0
        for decision in Decision.allCases {
            let missing = patterns(decision).filter { !chosen.contains($0) }
            guard !missing.isEmpty else { continue }
            added += missing.count
            if let index = permissions.firstIndex(where: { $0.0 == decision.rawValue }), case .array(let entries) = permissions[index].1 {
                permissions[index].1 = .array(entries + missing.map(OrderedJSON.string))
            } else {
                permissions.append((decision.rawValue, .array(missing.map(OrderedJSON.string))))
            }
        }
        guard added > 0 else { return Merge(content: nil, added: 0) }
        if let permissionsIndex {
            root[permissionsIndex].1 = .object(permissions)
        } else {
            root.append(("permissions", .object(permissions)))
        }
        return Merge(content: Data((OrderedJSON.object(root).rendered() + "\n").utf8), added: added)
    }

    public static let codexHeader = "# Offsider's permission rules for Codex, from offsider init. Edit freely: init only adds missing rules.\n"

    /// Appends the missing `prefix_rule` lines to Offsider's own Codex rules file; nothing else in it changes.
    static func mergeCodexRules(_ existing: Data?) throws -> Merge {
        var text = ""
        if let existing {
            guard let decoded = String(validating: existing, as: UTF8.self) else { throw MergeError.malformed("is not UTF-8 text") }
            text = decoded
        }
        let missing = rules.filter { !text.contains($0.codexKey) }
        guard !missing.isEmpty else { return Merge(content: nil, added: 0) }
        if text.isEmpty {
            text = codexHeader
        } else if !text.hasSuffix("\n") {
            text += "\n"
        }
        text += missing.map { $0.codexRule + "\n" }.joined()
        return Merge(content: Data(text.utf8), added: missing.count)
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

    /// One line per file: `Rules added to ~/.claude/settings.json (15 new)` or `Rules already present in ...`.
    public static func resultLine(path: String, added: Int) -> String {
        added == 0 ? "Rules already present in \(path)" : "Rules added to \(path) (\(added) new)"
    }

    public static func failureLine(path: String, error: MergeError) -> String {
        let problem: String
        switch error {
        case .tooLarge: problem = "is over 1 MiB"
        case .malformed(let detail): problem = detail
        }
        return "\(path) \(problem), so it was left as is. Fix it, then run offsider init --rules-only."
    }

    /// `install.rules`: every installed agent has every rule; `lacking` names the agents that do not.
    public static func doctorVerdict(detected: [Agent], lacking: [Agent]) -> DoctorRules.Verdict {
        if detected.isEmpty {
            return (.skip, "No Claude Code or Codex folder found", nil)
        }
        if !lacking.isEmpty {
            return (.warn, "\(lacking.map(\.name).joined(separator: " and ")) \(lacking.count == 1 ? "lacks" : "lack") Offsider's permission rules", "Run offsider init --rules-only.")
        }
        return (.pass, "\(detected.map(\.name).joined(separator: " and ")) \(detected.count == 1 ? "has" : "have") Offsider's permission rules", nil)
    }
}
