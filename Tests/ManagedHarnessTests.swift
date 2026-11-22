import Foundation
@testable import Offsider
@testable import OffsiderCore
import Testing

@Suite("Managed agent settings")
struct ManagedHarnessTests {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()

    /// A Mac's managed agent settings as files and forced preferences, all in memory.
    static func probe(
        files: [String: String] = [:], forced: [String: ManagedPreferenceValue] = [:], forcedText: [String: String] = [:],
        profileRules: [String: [String]] = [:], userSkill: Bool = true
    ) -> ManagedHarness.Probe {
        ManagedHarness.Probe(
            file: { files[$0].map { Data($0.utf8) } },
            names: { folder in files.keys.filter { $0.hasPrefix(folder + "/") }.map { String($0.dropFirst(folder.count + 1)) } },
            forced: { forced["\($0):\($1)"] },
            forcedText: { forcedText["\($0):\($1)"] },
            forcedLists: { domain, key in domain == ManagedHarness.claudeDomain && key == "permissions" ? profileRules : [:] },
            userSkill: { userSkill },
            profileKeys: { domain in
                (forced.keys.sorted() + forcedText.keys.sorted()).filter { $0.hasPrefix(domain + ":") }.map { String($0.dropFirst(domain.count + 1)) }
                    + (domain == ManagedHarness.claudeDomain && !profileRules.isEmpty ? ["permissions"] : [])
            }
        )
    }

    static let dropIn = ManagedHarness.claudeDropIns + "/" + ManagedHarness.claudeDropInName

    @Test("a Mac with no managed agent settings asks for nothing and doctor skips the check")
    func unmanaged() {
        let found = ManagedHarness.read(Self.probe())
        #expect(found == ManagedHarness())
        #expect(found.asks().isEmpty)
        #expect(found.doctorVerdict.status == .skip)
    }

    @Test("allowManagedPermissionRulesOnly drops init's rules, from the file, a drop-in or the profile, and a wrong type counts as on", arguments: [
        [ManagedHarness.claudeFile: #"{"allowManagedPermissionRulesOnly": true}"#],
        [ManagedHarness.claudeDropIns + "/10-locks.json": #"{"allowManagedPermissionRulesOnly": true}"#],
        [ManagedHarness.claudeFile: #"{"allowManagedPermissionRulesOnly": "yes"}"#],
    ])
    func rulesLock(files: [String: String]) {
        let found = ManagedHarness.read(Self.probe(files: files))
        #expect(found.rulesDropped && found.claudeManaged)
        #expect(found.asks().count == 1)
        #expect(found.asks()[0].contains("(allowManagedPermissionRulesOnly)") && found.asks()[0].contains("`offsider init --print-managed`"))
        #expect(found.doctorVerdict.status == .warn)
        let profile = ManagedHarness.read(Self.probe(forced: ["com.anthropic.claudecode:allowManagedPermissionRulesOnly": .bool(true)]))
        #expect(profile.rulesDropped)
    }

    @Test("once the administrator deploys the printed fragment, the lock drops nothing")
    func fragmentRestoresRules() {
        let files = [
            ManagedHarness.claudeFile: #"{"allowManagedPermissionRulesOnly": true}"#,
            Self.dropIn: ManagedHarness.claudeFragment(),
        ]
        let found = ManagedHarness.read(Self.probe(files: files))
        #expect(!found.rulesDropped)
        #expect(found.asks().isEmpty)
        #expect(found.doctorVerdict.status == .pass)
    }

    @Test("rules deployed through the profile count as deployed, and a profile without them does not")
    func profileRestoresRules() {
        let lock = ["com.anthropic.claudecode:allowManagedPermissionRulesOnly": ManagedPreferenceValue.bool(true)]
        let carried = ManagedHarness.read(Self.probe(forced: lock, profileRules: ["ask": AgentPermissionRules.patterns(.ask)]))
        #expect(!carried.rulesDropped && carried.claudeManaged)
        let partial = ManagedHarness.read(Self.probe(forced: lock, profileRules: ["ask": Array(AgentPermissionRules.patterns(.ask).dropLast())]))
        #expect(partial.rulesDropped)
        let rulesOnly = ManagedHarness.read(Self.probe(profileRules: ["ask": AgentPermissionRules.patterns(.ask)]))
        #expect(rulesOnly.claudeManaged && rulesOnly.doctorVerdict.status == .pass)
    }

    @Test("a profile wins over the files as Claude Code reads them: a fragment in a file does not answer a lock in the profile unless the sources merge")
    func profileBeforeFiles() {
        let lock = ["com.anthropic.claudecode:allowManagedPermissionRulesOnly": ManagedPreferenceValue.bool(true)]
        let files = [Self.dropIn: ManagedHarness.claudeFragment()]
        #expect(ManagedHarness.read(Self.probe(files: files, forced: lock)).rulesDropped)
        let merged = ManagedHarness.read(Self.probe(files: files, forced: lock, forcedText: ["com.anthropic.claudecode:managedSourcesBehavior": "merge"]))
        #expect(!merged.rulesDropped)
        let fileMerges = ManagedHarness.read(Self.probe(files: files.merging([ManagedHarness.claudeFile: #"{"managedSourcesBehavior": "merge"}"#]) { $1 }, forced: lock))
        #expect(!fileMerges.rulesDropped)
        let ignoredFileLock = ManagedHarness.read(Self.probe(
            files: [ManagedHarness.claudeFile: #"{"allowManagedPermissionRulesOnly": true}"#], forced: ["com.anthropic.claudecode:strictPluginOnlyCustomization": .bool(false)]
        ))
        #expect(!ignoredFileLock.rulesDropped && ignoredFileLock.claudeManaged)
    }

    @Test("init asks only about the agents and skill it handled, and doctor names both locks at once")
    func scopedAsks() {
        let both = ManagedHarness.read(Self.probe(files: [
            ManagedHarness.claudeFile: #"{"allowManagedPermissionRulesOnly": true, "strictPluginOnlyCustomization": true}"#,
            ManagedHarness.codexFile: "allowed_approval_policies = []\n",
        ]))
        #expect(both.asks().count == 3)
        #expect(both.asks(rules: [], skill: false).isEmpty)
        #expect(both.asks(rules: [.codex], skill: false).count == 1 && both.asks(rules: [.codex], skill: false)[0].hasPrefix("Codex "))
        #expect(both.asks(rules: [.claudeCode], skill: false).count == 1 && both.asks(rules: [.claudeCode], skill: false)[0].contains("(allowManagedPermissionRulesOnly)"))
        #expect(both.asks(rules: [], skill: true).count == 1 && both.asks(rules: [], skill: true)[0].contains("(strictPluginOnlyCustomization)"))
        let verdict = both.doctorVerdict
        #expect(verdict.status == .warn)
        #expect(verdict.detail.contains("(allowManagedPermissionRulesOnly)") && verdict.detail.contains("(strictPluginOnlyCustomization)"))
        #expect(verdict.hint?.contains("offsider init --print-managed") == true && verdict.hint?.contains("~/.claude/skills/offsider") == true)
    }

    @Test("a lock set to false, a hidden or non-JSON drop-in and a malformed file lock nothing")
    func notLocked() {
        let files = [
            ManagedHarness.claudeFile: #"{"allowManagedPermissionRulesOnly": false, "strictPluginOnlyCustomization": false}"#,
            ManagedHarness.claudeDropIns + "/.hidden.json": #"{"allowManagedPermissionRulesOnly": true}"#,
            ManagedHarness.claudeDropIns + "/notes.txt": #"{"allowManagedPermissionRulesOnly": true}"#,
            ManagedHarness.claudeDropIns + "/20-broken.json": #"{"allowManagedPermissionRulesOnly": true"#,
        ]
        let found = ManagedHarness.read(Self.probe(files: files))
        #expect(!found.rulesDropped && !found.skillDropped && found.claudeManaged)
        #expect(found.doctorVerdict.status == .pass)
    }

    @Test("strictPluginOnlyCustomization drops an installed skill when it is true or names skills, not for other surfaces, and not once the skill is removed")
    func skillLock() {
        for value in ["true", #"["skills", "hooks"]"#, #""all""#] {
            let found = ManagedHarness.read(Self.probe(files: [ManagedHarness.claudeFile: "{\"strictPluginOnlyCustomization\": \(value)}"]))
            #expect(found.skillDropped, "\(value) did not read as a skills lock")
            #expect(found.asks().count == 1 && found.asks()[0].contains("(strictPluginOnlyCustomization)"))
            #expect(found.doctorVerdict.status == .warn)
        }
        #expect(!ManagedHarness.read(Self.probe(files: [ManagedHarness.claudeFile: #"{"strictPluginOnlyCustomization": ["hooks", "mcp"]}"#])).skillDropped)
        #expect(ManagedHarness.read(Self.probe(forced: ["com.anthropic.claudecode:strictPluginOnlyCustomization": .strings(["skills"])])).skillDropped)
        #expect(!ManagedHarness.read(Self.probe(forced: ["com.anthropic.claudecode:strictPluginOnlyCustomization": .strings(["agents"])])).skillDropped)
        let removed = ManagedHarness.read(Self.probe(files: [ManagedHarness.claudeFile: #"{"strictPluginOnlyCustomization": true}"#], userSkill: false))
        #expect(!removed.skillDropped && removed.asks().isEmpty && removed.doctorVerdict.status == .pass)
    }

    @Test("managed Codex requirements without Offsider's rules get one ask, from the file or the profile; with the snippet, none")
    func codex() {
        let bare = ManagedHarness.read(Self.probe(files: [ManagedHarness.codexFile: "allowed_approval_policies = [\"on-request\"]\n"]))
        #expect(bare.codexManaged && bare.codexLacksRules)
        #expect(bare.asks().count == 1 && bare.asks()[0].contains("[rules]"))
        #expect(bare.doctorVerdict.status == .pass)

        let carried = ManagedHarness.read(Self.probe(files: [ManagedHarness.codexFile: ManagedHarness.codexFragment()]))
        #expect(carried.codexManaged && !carried.codexLacksRules && carried.asks().isEmpty)

        let encoded = Data(ManagedHarness.codexFragment().utf8).base64EncodedString()
        let profile = ManagedHarness.read(Self.probe(forcedText: ["com.openai.codex:requirements_toml_base64": encoded]))
        #expect(profile.codexManaged && !profile.codexLacksRules)
        let empty = ManagedHarness.read(Self.probe(forcedText: ["com.openai.codex:requirements_toml_base64": "bm90IHJ1bGVz"]))
        #expect(empty.codexManaged && empty.codexLacksRules)
    }

    @Test("the Claude Code fragment is the ask rules init installs, as one settings document")
    func claudeFragment() throws {
        let json = try #require(JSONSerialization.jsonObject(with: Data(ManagedHarness.claudeFragment().utf8)) as? [String: Any])
        #expect(Array(json.keys) == ["permissions"])
        let permissions = try #require(json["permissions"] as? [String: [String]])
        #expect(permissions["ask"] == AgentPermissionRules.patterns(.ask))
        #expect(permissions["deny"] == (AgentPermissionRules.patterns(.deny).isEmpty ? nil : AgentPermissionRules.patterns(.deny)))
        #expect(permissions["allow"] == nil)
    }

    @Test("the Codex snippet holds every rule Codex can express, as token tables that only prompt or forbid")
    func codexFragment() {
        let lines = ManagedHarness.codexFragment().split(separator: "\n").map(String.init)
        #expect(lines.first == "[rules]" && lines.dropFirst().first == "prefix_rules = [" && lines.last == "]")
        let rules = lines.dropFirst(2).dropLast()
        #expect(rules.count == AgentPermissionRules.codexRules.count)
        for (line, rule) in zip(rules, AgentPermissionRules.codexRules) {
            #expect(line.contains("pattern = [" + rule.codex.map { "{ token = \"\($0)\" }" }.joined(separator: ", ") + "]"))
            #expect(line.contains("decision = \"prompt\"") || line.contains("decision = \"forbidden\""))
            #expect(!line.contains("\"allow\""))
        }
        #expect(ManagedHarness.tomlString(#"a "quoted" \ path"#) == #""a \"quoted\" \\ path""#)
    }

    @Test("init --print-managed prints both fragments with where each goes, and takes no other option")
    func printed() throws {
        let text = ManagedHarness.printed()
        #expect(text.contains(ManagedHarness.claudeFragment()) && text.contains(ManagedHarness.codexFragment()))
        #expect(text.contains("/Library/Application Support/ClaudeCode/managed-settings.d/50-offsider.json"))
        #expect(text.contains("/etc/codex/requirements.toml") && text.contains("requirements_toml_base64"))
        #expect(text.contains("sandbox.excludedCommands"))
        _ = try Init.parse(["--print-managed"])
        for other in [["--rules-only"], ["--print-rules"], ["--print"], ["--uninstall"], ["--client", "claude"], ["--dest", "/tmp/skills"], ["--no-rules"], ["--force"]] {
            #expect(throws: (any Error).self) { _ = try Init.parse(["--print-managed"] + other) }
        }
    }

    @Test("the fragments under docs/mdm are what init --print-managed prints")
    func committedFragments() throws {
        let folder = Self.root.appendingPathComponent("docs/mdm")
        #expect(try String(contentsOf: folder.appendingPathComponent("claude-code-managed-settings.json"), encoding: .utf8) == ManagedHarness.claudeFragment())
        #expect(try String(contentsOf: folder.appendingPathComponent("codex-requirements.toml"), encoding: .utf8) == ManagedHarness.codexFragment())
    }

    @Test("doctor ends with managed.policy and harness.managed, read through their seams")
    func doctorChecks() {
        let checks = ManagedGate.$sourceOverride.withValue(FakeManagedPreferences(values: ["forceMasks": .bool(true)])) {
            Doctor.managedChecks(harness: Self.probe(files: [ManagedHarness.claudeFile: #"{"allowManagedPermissionRulesOnly": true}"#]))
        }
        #expect(checks.map(\.id) == [.managedPolicy, .harnessManaged])
        #expect(checks[0].status == .pass && checks[0].detail == "forceMasks=true")
        #expect(checks[1].status == .warn && checks[1].hint?.contains("offsider init --print-managed") == true)
        let quiet = ManagedGate.$sourceOverride.withValue(FakeManagedPreferences()) { Doctor.managedChecks(harness: Self.probe()) }
        #expect(quiet.map(\.status) == [.skip, .skip])
    }
}
