import Foundation

/// What an administrator's own settings for Claude Code and Codex do to the rules and skill `offsider init` installs, and the fragments that restore them.
public struct ManagedHarness: Equatable, Sendable {
    public static let claudeDirectory = "/Library/Application Support/ClaudeCode"
    public static let claudeFile = claudeDirectory + "/managed-settings.json"
    public static let claudeDropIns = claudeDirectory + "/managed-settings.d"
    public static let claudeDropInName = "50-offsider.json"
    public static let claudeDomain = "com.anthropic.claudecode"
    public static let rulesLockKey = "allowManagedPermissionRulesOnly"
    public static let customisationLockKey = "strictPluginOnlyCustomization"
    public static let codexFile = "/etc/codex/requirements.toml"
    public static let codexDomain = "com.openai.codex"
    public static let codexRequirementsKey = "requirements_toml_base64"
    public static let printCommand = "offsider init --print-managed"

    /// Everything the check reads; tests bind their own, so nothing under `/Library` or `/etc` is ever written.
    public struct Probe: Sendable {
        public var file: @Sendable (String) -> Data?
        /// The names in a folder, unsorted; empty when it is missing.
        public var names: @Sendable (String) -> [String]
        public var forced: @Sendable (_ domain: String, _ key: String) -> ManagedPreferenceValue?
        /// A forced string, which `ManagedPreferenceValue` does not carry.
        public var forcedText: @Sendable (_ domain: String, _ key: String) -> String?
        /// The lists of strings inside a forced dictionary, such as a profile's `permissions`.
        public var forcedLists: @Sendable (_ domain: String, _ key: String) -> [String: [String]]
        /// Whether `init` left a skill in the person's own Claude Code folder, which a skills lock ignores.
        public var userSkill: @Sendable () -> Bool

        public init(
            file: @escaping @Sendable (String) -> Data?, names: @escaping @Sendable (String) -> [String],
            forced: @escaping @Sendable (String, String) -> ManagedPreferenceValue?, forcedText: @escaping @Sendable (String, String) -> String? = { _, _ in nil },
            forcedLists: @escaping @Sendable (String, String) -> [String: [String]] = { _, _ in [:] }, userSkill: @escaping @Sendable () -> Bool = { false }
        ) {
            self.file = file
            self.names = names
            self.forced = forced
            self.forcedText = forcedText
            self.forcedLists = forcedLists
            self.userSkill = userSkill
        }

        /// Claude Code follows a symlinked settings file, so the read does too.
        public static func live(home: String) -> Probe {
            Probe(
                file: { UntrustedRead.contents(atPath: URL(fileURLWithPath: $0).resolvingSymlinksInPath().path, maxBytes: AgentPermissionRules.maxFileBytes) },
                names: { (try? FileManager.default.contentsOfDirectory(atPath: $0)) ?? [] },
                forced: { LiveManagedPreferences(domain: $0).forcedValue(forKey: $1) },
                forcedText: { LiveManagedPreferences(domain: $0).forcedText(forKey: $1) },
                forcedLists: { LiveManagedPreferences(domain: $0).forcedLists(forKey: $1) },
                userSkill: { FileManager.default.fileExists(atPath: home + "/" + userSkillPath) }
            )
        }
    }

    static let userSkillPath = ".claude/skills/offsider/SKILL.md"

    /// Claude Code takes permission rules from managed settings only, and those do not carry Offsider's.
    public var rulesDropped = false
    /// Claude Code loads skills from managed sources only, and a skill `init` installed sits where it no longer looks.
    public var skillDropped = false
    /// Managed Claude Code settings exist on this Mac.
    public var claudeManaged = false
    /// Codex has managed requirements that do not carry Offsider's rules.
    public var codexLacksRules = false
    public var codexManaged = false

    public init() {}

    public static func read(_ probe: Probe) -> ManagedHarness {
        var found = ManagedHarness()
        let dropIns = probe.names(claudeDropIns).filter { $0.hasSuffix(".json") && !$0.hasPrefix(".") }.sorted().map { claudeDropIns + "/" + $0 }
        let documents = ([claudeFile] + dropIns).compactMap { probe.file($0) }.compactMap { data -> [(String, OrderedJSON)]? in
            guard let parsed = try? OrderedJSON.parse(data), case .object(let members) = parsed else { return nil }
            return members
        }
        let forcedRulesLock = probe.forced(claudeDomain, rulesLockKey)
        let forcedCustomisation = probe.forced(claudeDomain, customisationLockKey)
        found.claudeManaged = !documents.isEmpty || forcedRulesLock != nil || forcedCustomisation != nil

        var rulesLock = forcedRulesLock.map { $0 != .bool(false) } ?? false
        var skillsLock = forcedCustomisation.map { value in
            if case .strings(let surfaces) = value { return surfaces.contains("skills") }
            return value != .bool(false)
        } ?? false
        var lists = probe.forcedLists(claudeDomain, "permissions").filter { ["allow", "ask", "deny"].contains($0.key) }
        for members in documents {
            for (key, value) in members {
                switch (key, value) {
                case (rulesLockKey, .bool(false)), (customisationLockKey, .bool(false)): break
                case (rulesLockKey, _): rulesLock = true
                case (customisationLockKey, .array(let surfaces)): if surfaces.contains(where: { if case .string("skills") = $0 { return true } else { return false } }) { skillsLock = true }
                case (customisationLockKey, _): skillsLock = true
                case ("permissions", .object(let permissions)):
                    for (list, entries) in permissions where ["allow", "ask", "deny"].contains(list) {
                        guard case .array(let patterns) = entries else { continue }
                        lists[list, default: []] += patterns.compactMap { if case .string(let pattern) = $0 { return pattern } else { return nil } }
                    }
                default: break
                }
            }
        }
        let carried = AgentPermissionRules.rules.allSatisfy { AgentPermissionRules.isDecided($0, lists: lists, moved: []) }
        found.rulesDropped = rulesLock && !carried
        found.skillDropped = skillsLock && probe.userSkill()

        var requirements = probe.file(codexFile).map { String(decoding: $0, as: UTF8.self) }
        if let encoded = probe.forcedText(codexDomain, codexRequirementsKey) {
            let decoded = Data(base64Encoded: encoded, options: .ignoreUnknownCharacters).map { String(decoding: $0, as: UTF8.self) } ?? ""
            requirements = (requirements ?? "") + "\n" + decoded
        }
        if let requirements {
            found.codexManaged = true
            found.codexLacksRules = !(requirements.contains("prefix_rules") && requirements.contains("\"offsider\""))
        }
        return found
    }

    static let rulesFix = "Ask your administrator to deploy what `\(printCommand)` prints."
    static let skillFix = "Ask your administrator to deploy the skill as a managed skill or plugin (`offsider init --print` prints it), then remove ~/.claude/skills/offsider."

    /// One line per thing to ask the administrator for, for the agents and skill this `init` handled; empty when nothing is missing.
    public func asks(rules: [AgentPermissionRules.Agent] = AgentPermissionRules.Agent.allCases, skill: Bool = true) -> [String] {
        var lines: [String] = []
        if rulesDropped, rules.contains(.claudeCode) {
            lines.append("Claude Code takes permission rules only from managed settings here (\(Self.rulesLockKey)), so the rules init adds are ignored. \(Self.rulesFix)")
        }
        if skillDropped, skill {
            lines.append("Claude Code loads skills only from managed sources here (\(Self.customisationLockKey)), so the skill in ~/.claude/skills is not loaded. \(Self.skillFix)")
        }
        if codexLacksRules, rules.contains(.codex) {
            lines.append("Codex has managed requirements here. Ask your administrator to add the [rules] snippet `\(Self.printCommand)` prints, so its prompts hold for everyone.")
        }
        return lines
    }

    /// `doctor`'s `harness.managed`.
    public var doctorVerdict: DoctorRules.Verdict {
        guard claudeManaged || codexManaged else { return (.skip, "No managed Claude Code or Codex settings found", nil) }
        let dropped = [
            rulesDropped ? ("Claude Code ignores the rules init adds (\(Self.rulesLockKey)), and its managed settings lack them", Self.rulesFix) : nil,
            skillDropped ? ("Claude Code does not load the skill in ~/.claude/skills (\(Self.customisationLockKey))", Self.skillFix) : nil,
        ].compactMap { $0 }
        if !dropped.isEmpty {
            return (.warn, dropped.map(\.0).joined(separator: "; "), dropped.map(\.1).joined(separator: " "))
        }
        if codexLacksRules {
            return (.pass, "Codex has managed requirements without Offsider's rules; the rules init adds still apply", "`\(Self.printCommand)` prints the snippet an administrator adds.")
        }
        return (.pass, "No managed lock drops Offsider's rules or skill", nil)
    }

    // MARK: Fragments

    /// The `permissions` an administrator deploys for Claude Code: the rules `init` adds, as a whole settings document.
    public static func claudeFragment() -> String {
        let lists = AgentPermissionRules.Decision.allCases.compactMap { decision -> (String, OrderedJSON)? in
            let patterns = AgentPermissionRules.patterns(decision)
            return patterns.isEmpty ? nil : (decision.rawValue, .array(patterns.map(OrderedJSON.string)))
        }
        return OrderedJSON.object([("permissions", .object(lists))]).rendered() + "\n"
    }

    /// The `[rules]` table an administrator adds to Codex's `requirements.toml`, where a rule may only prompt or forbid.
    public static func codexFragment() -> String {
        let rules = AgentPermissionRules.codexRules.map { rule in
            let tokens = rule.codex.map { "{ token = \(tomlString($0)) }" }.joined(separator: ", ")
            return "  { pattern = [\(tokens)], decision = \(tomlString(rule.decision.codex)), justification = \(tomlString(rule.reason)) },"
        }
        return (["[rules]", "prefix_rules = ["] + rules + ["]"]).joined(separator: "\n") + "\n"
    }

    static func tomlString(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    public static let sandboxNote = "If your managed settings turn Claude Code's sandbox on, also add \"offsider *\" to sandbox.excludedCommands: the sandbox blocks the Unix sockets and loopback ports Offsider uses to reach simulators, emulators and phones. An excluded command still passes the rules above."

    /// `init --print-managed`: both fragments, each under where it goes. Nothing is written.
    public static func printed() -> String {
        [
            "Claude Code: save as \(claudeDropIns)/\(claudeDropInName), or merge into \(claudeFile) or your \(claudeDomain) profile.",
            "",
            claudeFragment(),
            sandboxNote,
            "",
            "Codex: add to \(codexFile), or to \(codexRequirementsKey) in your \(codexDomain) profile.",
            "",
            codexFragment(),
        ].joined(separator: "\n")
    }
}
