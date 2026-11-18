import Foundation
import Testing
@testable import Offsider
@testable import OffsiderCore

@Suite("Plan-blocking agent rules")
struct PlanBlockingRulesTests {
    @Test("a deny rule that matches devices add --plan as Claude Code matches it counts; an exact devices add, another command or every command does not", arguments: [
        ("Bash(offsider devices add*)", true),
        ("Bash(offsider devices add:*)", true),
        ("Bash(offsider devices add *)", true),
        ("Bash(offsider devices add --plan*)", true),
        ("Bash(offsider devices add --plan --json)", true),
        ("Bash(offsider devices*)", true),
        ("Bash(offsider *)", true),
        ("Bash(offsider devices add)", false),
        ("Bash(offsider devices remove*)", false),
        ("Bash(offsider device add*)", false),
        ("Bash(Offsider devices add*)", false),
        ("Bash(offsider devices add* --force)", false),
        ("Bash(offsider devices:* add)", false),
        ("Bash(*)", false),
        ("Bash", false),
        ("Read(offsider devices add*)", false),
    ])
    func claudeRule(rule: String, blocks: Bool) {
        #expect(PlanBlockingRules.planCommands.contains { PlanBlockingRules.claudeMatches(rule, command: $0) } == blocks)
    }

    @Test("the matcher follows the examples in Claude Code's permission docs", arguments: [
        ("Bash(npm run build)", "npm run build", true), ("Bash(npm run build)", "npm run build --watch", false),
        ("Bash(npm run *)", "npm run", true), ("Bash(npm run *)", "npm install", false),
        ("Bash(git * main)", "git push origin main", true), ("Bash(git * main)", "git log", false),
        ("Bash(ls *)", "ls -la", true), ("Bash(ls *)", "lsof", false), ("Bash(ls*)", "lsof", true),
        ("Bash(ls:*)", "ls", true), ("Bash(* --help *)", "npm --help x", true), ("Bash(* --help *)", "npm --help", false),
    ] as [(String, String, Bool)])
    func documentedMatching(rule: String, command: String, matches: Bool) {
        #expect(PlanBlockingRules.claudeMatches(rule, command: command) == matches)
    }

    static func claude(_ permissions: String) -> Data { Data(#"{"theme": "dark", "permissions": \#(permissions)}"#.utf8) }

    @Test("only a deny that blocks the plan is found: an allow, an ask, an unrelated deny or a broken file is silent")
    func claudeFiles() {
        let rule = "Bash(offsider devices add*)"
        let found = { (data: Data) in PlanBlockingRules.findings([(.claudeSettings, "~/.claude/settings.json", data)]) }
        #expect(found(Self.claude(#"{"deny": ["Bash(rm -rf *)", 7, "\#(rule)"]}"#)) == [PlanBlockingRules.Finding(file: "~/.claude/settings.json", rule: rule)])
        #expect(found(Self.claude(#"{"allow": ["\#(rule)"], "ask": ["\#(rule)"], "deny": ["Bash(rm -rf *)"]}"#)).isEmpty)
        #expect(found(Self.claude(#"{"deny": "\#(rule)"}"#)).isEmpty)
        #expect(found(Data(#"{"permissions": {"deny": ["\#(rule)"],}"#.utf8)).isEmpty)
        #expect(found(Data("[]".utf8)).isEmpty)
    }

    @Test("a Codex rule forbidding devices add counts; one that prompts, or forbids another command, does not")
    func codexFiles() {
        let forbidden = #"prefix_rule(pattern=["offsider", "devices", "add"], decision="forbidden", justification="Allows physical devices; a person runs it.")"#
        let text = AgentPermissionRules.codexHeader + forbidden + "\n"
            + #"prefix_rule(pattern=["offsider", "devices", "add"], decision="prompt", justification="x")"# + "\n"
            + #"prefix_rule(pattern=["offsider", "devices", "remove"], decision="forbidden", justification="x")"# + "\n"
        let findings = PlanBlockingRules.findings([(.codexRules, "~/.codex/rules/offsider.rules", Data(text.utf8))])
        #expect(findings == [PlanBlockingRules.Finding(file: "~/.codex/rules/offsider.rules", rule: forbidden)])
    }

    @Test("the files are the user's, the folder's, its repository root's and a worktree's main checkout's, each once, then Codex's")
    func candidateFiles() {
        let entries: [String: PlanBlockingRules.GitEntry] = [
            "/work/app/.git": .directory,
            "/work/app/.claude/worktrees/fix/.git": .file("gitdir: /work/app/.git/worktrees/fix\n"),
        ]
        let inRepo = PlanBlockingRules.files(home: "/work/home", directory: "/work/app/Sources", gitEntry: { entries[$0] }).map(\.path)
        #expect(inRepo == [
            "/work/home/.claude/settings.json", "/work/home/.claude/settings.local.json",
            "/work/app/Sources/.claude/settings.json", "/work/app/Sources/.claude/settings.local.json",
            "/work/app/.claude/settings.json", "/work/app/.claude/settings.local.json",
            "/work/home/.codex/rules/offsider.rules",
        ])
        let worktree = PlanBlockingRules.files(home: "/work/home", directory: "/work/app/.claude/worktrees/fix", gitEntry: { entries[$0] }).map(\.path)
        #expect(worktree.contains("/work/app/.claude/settings.local.json"))
        #expect(worktree.filter { $0 == "/work/app/.claude/worktrees/fix/.claude/settings.json" }.count == 1)
        #expect(PlanBlockingRules.files(home: "/work/home", directory: "/work/home", gitEntry: { _ in nil }).count == 3)
    }

    @Test("the warning names each file and quoted rule, says it blocks the plan, and leaves the fix to a person")
    func verdicts() {
        let finding = PlanBlockingRules.Finding(file: "~/.claude/settings.json", rule: "Bash(offsider devices add*)")
        let agent = PlanBlockingRules.verdict([finding], filesRead: 1, audience: .agent)
        #expect(agent.status == .warn)
        #expect(agent.detail == #"~/.claude/settings.json denies "Bash(offsider devices add*)", which also blocks the read-only `offsider devices add --plan`, so an agent cannot read the one command a person runs"#)
        #expect(agent.hint?.hasPrefix("Ask the user to remove it: `devices add` refuses without them at the terminal and Touch ID anyway.") == true)
        #expect(agent.hint?.contains("Never edit the file yourself.") == true)
        #expect(PlanBlockingRules.verdict([finding], filesRead: 1, audience: .person).hint == "Remove it if you like: `devices add` refuses without you at the terminal and Touch ID anyway.")
        #expect(PlanBlockingRules.verdict([], filesRead: 2).status == .pass)
        #expect(PlanBlockingRules.verdict([], filesRead: 0).status == .skip)
        let hostile = PlanBlockingRules.verdict([PlanBlockingRules.Finding(file: "~/.claude/settings.json", rule: "Bash(offsider devices add*\u{1B}[2J)")], filesRead: 1)
        #expect(!hostile.detail.contains("\u{1B}"))
    }

    @Test("doctor reads the user's and the project's settings without changing them, and offers no fix")
    func doctorReadsOnly() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("plan-rules-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home")
        let project = home.appendingPathComponent("app")
        for folder in [home.appendingPathComponent(".claude"), project.appendingPathComponent(".git"), project.appendingPathComponent(".claude"), project.appendingPathComponent("Sources")] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        let user = home.appendingPathComponent(".claude/settings.json")
        let local = project.appendingPathComponent(".claude/settings.local.json")
        try Data("{ not json".utf8).write(to: user)
        try Self.claude(#"{"deny": ["Bash(offsider devices add:*)"]}"#).write(to: local)
        let before = try Data(contentsOf: local)

        let check = Init.denyRulesDoctorCheck(home: home.path, directory: project.appendingPathComponent("Sources").path, audience: .agent)
        #expect(check.id == .installDenyRules)
        #expect(check.status == .warn)
        #expect(check.detail.hasPrefix(#"~/app/.claude/settings.local.json denies "Bash(offsider devices add:*)""#))
        #expect(!check.fixable)
        #expect(try Data(contentsOf: local) == before)

        try FileManager.default.removeItem(at: local)
        #expect(Init.denyRulesDoctorCheck(home: home.path, directory: project.path).status == .pass)

        // The rule an earlier `init` wrote into the user's file is `install.rules`' to name; a hand-written one there, or the same rule in a project file, still warns.
        try Self.claude(#"{"deny": ["Bash(offsider devices add*)"]}"#).write(to: user)
        #expect(Init.denyRulesDoctorCheck(home: home.path, directory: project.path).status == .pass)
        try Self.claude(#"{"deny": ["Bash(offsider devices add*)", "Bash(offsider devices:*)"]}"#).write(to: user)
        let handWritten = Init.denyRulesDoctorCheck(home: home.path, directory: project.path, audience: .agent)
        #expect(handWritten.status == .warn && handWritten.detail.hasPrefix(#"~/.claude/settings.json denies "Bash(offsider devices:*)""#))
        try Self.claude(#"{"deny": ["Bash(offsider devices add*)"]}"#).write(to: local)
        #expect(Init.denyRulesDoctorCheck(home: home.path, directory: project.path).status == .warn)
    }
}
