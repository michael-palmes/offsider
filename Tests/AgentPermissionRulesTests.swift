import Foundation
import Testing
@testable import Offsider
@testable import OffsiderCore

@Suite("Agent permission rules")
struct AgentPermissionRulesTests {
    private func settings(_ data: Data?) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: try #require(data))
        return try #require(object as? [String: Any])
    }

    private func permissions(_ data: Data?) throws -> [String: [String]] {
        let root = try settings(data)
        let block = try #require(root["permissions"] as? [String: Any])
        return block.compactMapValues { $0 as? [String] }
    }

    @Test("the person-only commands are denied and the sign-in, permission and raw device commands ask")
    func ruleSets() {
        let deny = AgentPermissionRules.patterns(.deny)
        let ask = AgentPermissionRules.patterns(.ask)
        for pattern in ["Bash(offsider credential join*)", "Bash(offsider unlock-code*)", "Bash(offsider wake --unlock*)", "Bash(offsider devices add*)",
                        "Bash(offsider describe-ui --raw-source*)", "Bash(offsider runner build --register-device*)"] {
            #expect(deny.contains(pattern))
        }
        for pattern in ["Bash(offsider credential add*)", "Bash(offsider login*)", "Bash(offsider permission*)", "Bash(offsider type --file*)",
                        "Bash(offsider screenshot --no-mask-secure*)", "Bash(offsider batch --no-mask-secure*)", "Bash(adb *)", "Bash(devicectl *)", "Bash(xcrun devicectl *)"] {
            #expect(ask.contains(pattern))
        }
        #expect(deny == deny.sorted())
        #expect(ask == ask.sorted())
        #expect(AgentPermissionRules.rules.allSatisfy { !$0.reason.isEmpty && !$0.reason.contains("\"") && !$0.reason.contains("\u{2014}") })
    }

    /// The `Bash(...)` patterns in `lists` that match `command` as Claude Code's prefix rules do.
    private func matches(_ command: String, _ patterns: [String]) -> Bool {
        patterns.contains { pattern in AgentPermissionRules.commandPrefix(pattern).map { command.hasPrefix($0) } ?? false }
    }

    @Test("every credential action that writes asks or is denied for both agents, and the read-only status runs freely")
    func credentialWritesAsk() {
        let guarded = AgentPermissionRules.patterns(.ask) + AgentPermissionRules.patterns(.deny)
        let actions = ["add"] + CredentialCommand.Action.allCases.map(\.rawValue)
        for action in actions {
            let command = "offsider credential \(action) --app com.example.app"
            let codex = AgentPermissionRules.rules.contains { ["offsider", "credential", action, "--app"].starts(with: $0.codex) }
            #expect(matches(command, guarded) == (action != "status"), "\(command)")
            #expect(codex == (action != "status"), "Codex: \(command)")
        }
    }

    @Test("Offsider's earlier broad credential rule gives way to the narrow ones, once, unless the person moved it")
    func broadCredentialRuleReplaced() throws {
        let broad = "Bash(offsider credential*)"
        let narrow = AgentPermissionRules.patterns(.ask).filter { $0.hasPrefix("Bash(offsider credential ") }
        #expect(narrow.count == 5)
        let older = Data(#"{"permissions": {"ask": ["Bash(git push*)", "Bash(offsider credential*)"]}}"#.utf8)
        let merge = try AgentPermissionRules.merge(.claudeCode, existing: older)
        let ask = try #require(try permissions(merge.content)["ask"])
        #expect(!ask.contains(broad))
        #expect(ask.first == "Bash(git push*)")
        #expect(narrow.allSatisfy(ask.contains))
        #expect(merge.replaced == 1)
        #expect(merge.added == AgentPermissionRules.rules.count)
        #expect(AgentPermissionRules.resultLine(path: "~/.claude/settings.json", added: merge.added, replaced: merge.replaced) == "Rules added to ~/.claude/settings.json (\(merge.added) new, 1 older replaced)")
        #expect(try AgentPermissionRules.merge(.claudeCode, existing: merge.content) == AgentPermissionRules.Merge(content: nil, added: 0))

        for list in ["allow", "deny"] {
            let moved = try AgentPermissionRules.merge(.claudeCode, existing: Data(#"{"permissions": {"\#(list)": ["Bash(offsider credential*)"]}}"#.utf8))
            let rules = try permissions(moved.content)
            #expect(rules[list]?.first == broad, "the person's own list keeps it")
            #expect(rules["ask"]?.contains { narrow.contains($0) } == false, "\(list) stands for the narrow rules")
            #expect(rules["deny"]?.contains("Bash(offsider credential join*)") == (list == "allow"), "a broad deny already denies join")
        }

        let both = try AgentPermissionRules.merge(.claudeCode, existing: Data(#"{"permissions": {"allow": ["Bash(offsider credential*)"], "ask": ["Bash(offsider credential*)"]}}"#.utf8))
        let rules = try permissions(both.content)
        #expect(rules["allow"] == [broad])
        #expect(narrow.allSatisfy { rules["ask"]?.contains($0) == true }, "init's ask outranked the allow, so the narrow asks take its place")
    }

    @Test("a person's rules that ask or deny at least as much count as present, in any spelling; a weaker or broad allow does not")
    func coveringRulesCount() throws {
        let theirs = AgentPermissionRules.rules.map { rule in
            rule.claude.hasPrefix("offsider credential ") && rule.decision == .ask ? "Bash(\(rule.claude.dropLast()):*)" : rule.claudePattern
        }
        let all = AgentPermissionRules.rules.map(\.claudePattern)
        let ask = theirs.filter { !AgentPermissionRules.patterns(.deny).contains($0) }
        let narrowed = Data(#"{"permissions": {"deny": \#(json(AgentPermissionRules.patterns(.deny))), "ask": \#(json(ask))}}"#.utf8)
        #expect(ask != AgentPermissionRules.patterns(.ask), "the credential rules are spelt the person's way")
        #expect(try AgentPermissionRules.merge(.claudeCode, existing: narrowed) == AgentPermissionRules.Merge(content: nil, added: 0))

        let broadAllow = try AgentPermissionRules.merge(.claudeCode, existing: Data(#"{"permissions": {"allow": ["Bash(offsider*)"], "ask": ["Bash(offsider unlock-code:*)"]}}"#.utf8))
        #expect(broadAllow.added == all.count, "an allow never stands in for a rule, and an ask never for a deny")
        let deniedAll = Data(#"{"permissions": {"deny": ["Bash(offsider *)"]}}"#.utf8)
        #expect(try AgentPermissionRules.merge(.claudeCode, existing: deniedAll).added == all.filter { !$0.hasPrefix("Bash(offsider ") }.count)
    }

    private func json(_ patterns: [String]) -> String {
        "[" + patterns.map { "\"\($0)\"" }.joined(separator: ", ") + "]"
    }

    @Test("Codex's earlier credential line is replaced by the narrow ones, and a person's broader prompt or moved line counts")
    func codexCredentialRules() throws {
        let older = AgentPermissionRules.codexHeader + #"prefix_rule(pattern=["offsider", "credential"], decision="prompt", justification="Saves, shares or removes test passwords.")"# + "\n"
        let merge = try AgentPermissionRules.merge(.codex, existing: Data(older.utf8))
        let text = String(decoding: try #require(merge.content), as: UTF8.self)
        #expect(!text.contains(#"pattern=["offsider", "credential"], decision"#))
        #expect(text.contains(#"prefix_rule(pattern=["offsider", "credential", "remove"], decision="prompt""#))
        #expect(merge.added == AgentPermissionRules.rules.count)
        #expect(merge.replaced == 1)
        #expect(try AgentPermissionRules.merge(.codex, existing: merge.content).added == 0)

        let commented = AgentPermissionRules.codexHeader + #"# prefix_rule(pattern=["offsider"], decision="forbidden")"# + "\n"
        #expect(try AgentPermissionRules.merge(.codex, existing: Data(commented.utf8)).added == AgentPermissionRules.rules.count, "a comment decides nothing")

        for decision in ["forbidden", "allow"] {
            let moved = older.replacingOccurrences(of: #"decision="prompt""#, with: #"decision="\#(decision)""#)
            let kept = try AgentPermissionRules.merge(.codex, existing: Data(moved.utf8))
            let keptText = String(decoding: try #require(kept.content), as: UTF8.self)
            #expect(keptText.hasPrefix(moved))
            #expect(!keptText.contains(#""credential", "add"]"#), "decision \(decision)")
            #expect(keptText.contains(#""credential", "join"], decision="forbidden""#) == (decision == "allow"), "a broad forbidden already forbids join")
        }

        let both = older + #"prefix_rule(pattern=["offsider", "credential"], decision="allow")"# + "\n"
        let replaced = String(decoding: try #require(try AgentPermissionRules.merge(.codex, existing: Data(both.utf8)).content), as: UTF8.self)
        #expect(replaced.contains(#"prefix_rule(pattern=["offsider", "credential", "add"], decision="prompt""#), "the prompt outranked the allow, so the narrow prompts take its place")
    }

    @Test("an agent counts as installed only when its own folder exists")
    func detection() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        #expect(AgentPermissionRules.detect(home: home.path).isEmpty)

        try FileManager.default.createDirectory(at: home.appendingPathComponent(".codex"), withIntermediateDirectories: true)
        #expect(AgentPermissionRules.detect(home: home.path) == [.codex])

        try Data().write(to: home.appendingPathComponent(".claude"))
        #expect(AgentPermissionRules.detect(home: home.path) == [.codex], "a plain file named .claude is not Claude Code")

        try FileManager.default.removeItem(at: home.appendingPathComponent(".claude"))
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        #expect(AgentPermissionRules.detect(home: home.path) == [.claudeCode, .codex])
    }

    @Test("merging keeps the person's settings and rules, adds only what is missing and leaves their own choices")
    func mergeKeepsExisting() throws {
        let existing = Data("""
        {"model": "opus", "permissions": {"allow": ["Bash(git status)", "Bash(adb *)"], "deny": ["Bash(rm -rf*)"]}, "env": {"A": "1", "N": 2.5}}
        """.utf8)
        let merge = try AgentPermissionRules.merge(.claudeCode, existing: existing)
        let total = AgentPermissionRules.rules.count
        #expect(merge.added == total - 1, "adb was already allowed by the person")

        let rules = try permissions(merge.content)
        #expect(rules["allow"] == ["Bash(git status)", "Bash(adb *)"])
        #expect(rules["deny"]?.first == "Bash(rm -rf*)")
        #expect(rules["deny"]?.contains("Bash(offsider devices add*)") == true)
        #expect(rules["ask"]?.contains("Bash(adb *)") == false)

        let text = String(decoding: try #require(merge.content), as: UTF8.self)
        let model = try #require(text.range(of: "\"model\""))
        let permissionsKey = try #require(text.range(of: "\"permissions\""))
        let env = try #require(text.range(of: "\"env\""))
        #expect(model.lowerBound < permissionsKey.lowerBound && permissionsKey.lowerBound < env.lowerBound, "key order is kept")
        let root = try settings(merge.content)
        #expect((root["env"] as? [String: Any])?["N"] as? Double == 2.5)

        let again = try AgentPermissionRules.merge(.claudeCode, existing: merge.content)
        #expect(again == AgentPermissionRules.Merge(content: nil, added: 0))
    }

    @Test("a missing or blank settings file gets a permissions block with every rule")
    func mergeFromNothing() throws {
        for existing in [nil, Data("\n".utf8)] {
            let merge = try AgentPermissionRules.merge(.claudeCode, existing: existing)
            #expect(merge.added == AgentPermissionRules.rules.count)
            let rules = try permissions(merge.content)
            #expect(rules["deny"] == AgentPermissionRules.patterns(.deny))
            #expect(rules["ask"] == AgentPermissionRules.patterns(.ask))
        }
    }

    @Test("a file that is not strict JSON, or holds the wrong shapes, is refused rather than rewritten")
    func malformedRefused() {
        let cases = ["{\"a\": 1,}", "// note\n{}", "[]", "{\"permissions\": []}", "{\"permissions\": {\"deny\": \"x\"}}", "{\"a\": 1, \"a\": 2}", "{\"a\": 01}"]
        for text in cases {
            #expect(throws: AgentPermissionRules.MergeError.self, Comment(rawValue: text)) {
                try AgentPermissionRules.merge(.claudeCode, existing: Data(text.utf8))
            }
        }
        #expect(throws: AgentPermissionRules.MergeError.tooLarge) {
            try AgentPermissionRules.merge(.claudeCode, existing: Data(count: AgentPermissionRules.maxFileBytes + 1))
        }
    }

    @Test("strings with escapes and non-ASCII text survive the round trip")
    func escapesRoundTrip() throws {
        let existing = Data(#"{"note": "line\none \"quoted\" é 😀 tab\t", "big": 12345678901234}"#.utf8)
        let merge = try AgentPermissionRules.merge(.claudeCode, existing: existing)
        let root = try settings(merge.content)
        #expect(root["note"] as? String == "line\none \"quoted\" é 😀 tab\t")
        #expect((root["big"] as? NSNumber)?.int64Value == 12_345_678_901_234)
    }

    @Test("Codex gets prefix rules with forbidden and prompt decisions, appended once")
    func codexRules() throws {
        let merge = try AgentPermissionRules.merge(.codex, existing: nil)
        let text = String(decoding: try #require(merge.content), as: UTF8.self)
        #expect(merge.added == AgentPermissionRules.rules.count)
        #expect(text.contains(#"prefix_rule(pattern=["offsider", "devices", "add"], decision="forbidden", justification="#))
        #expect(text.contains(#"prefix_rule(pattern=["offsider", "login"], decision="prompt", justification="#))
        #expect(!text.contains("untrusted"))
        #expect(try AgentPermissionRules.merge(.codex, existing: merge.content).added == 0)

        let edited = text.replacingOccurrences(of: "Signs in with a saved test password.", with: "My own words.")
            .replacingOccurrences(of: #"prefix_rule(pattern=["adb"], decision="prompt""#, with: "# removed")
        let topUp = try AgentPermissionRules.merge(.codex, existing: Data(edited.utf8))
        #expect(topUp.added == 1, "a reworded justification still counts; the removed adb rule comes back")
        #expect(String(decoding: try #require(topUp.content), as: UTF8.self).hasPrefix(edited))
    }

    @Test("doctor names the installed agents that lack the rules and the one command that adds them")
    func doctorVerdict() {
        #expect(AgentPermissionRules.doctorVerdict(detected: [], lacking: []).status == .skip)
        let lacking = AgentPermissionRules.doctorVerdict(detected: [.claudeCode, .codex], lacking: [.codex])
        #expect(lacking.status == .warn)
        #expect(lacking.detail.contains("Codex"))
        #expect(lacking.hint == "Run offsider init --rules-only.")
        #expect(AgentPermissionRules.doctorVerdict(detected: [.claudeCode], lacking: []).status == .pass)
        let outdated = AgentPermissionRules.doctorVerdict(detected: [.claudeCode], lacking: [], outdated: [.claudeCode])
        #expect(outdated.status == .warn)
        #expect(outdated.detail == "Claude Code has an older Offsider rule to replace")
        #expect(outdated.hint == "Run offsider init --rules-only.")
    }

    @Test("doctor warns about an older rule until init replaces it, and says lacks only when a rule is missing")
    func doctorAfterReplacement() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let claude = home.appendingPathComponent(".claude")
        try FileManager.default.createDirectory(at: claude, withIntermediateDirectories: true)
        let current = try #require(try AgentPermissionRules.merge(.claudeCode, existing: nil).content)
        var root = try settings(current)
        var block = try #require(root["permissions"] as? [String: [String]])
        block["ask"]?.append("Bash(offsider credential*)")
        root["permissions"] = block
        try JSONSerialization.data(withJSONObject: root).write(to: claude.appendingPathComponent("settings.json"))

        #expect(Init.rulesDoctorVerdict(home: home.path).detail == "Claude Code has an older Offsider rule to replace")
        #expect(Init.installRules([.claudeCode], home: home.path).lines == ["Rules updated in ~/.claude/settings.json (1 older replaced)"])
        #expect(Init.rulesDoctorVerdict(home: home.path).status == .pass)
    }

    @Test("installing writes 0600 through a symlink, says how many were added, then says they are present")
    func installWritesAndIsIdempotent() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let claude = home.appendingPathComponent(".claude")
        let dotfiles = home.appendingPathComponent("dotfiles")
        try FileManager.default.createDirectory(at: claude, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dotfiles, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".codex"), withIntermediateDirectories: true)
        let real = dotfiles.appendingPathComponent("settings.json")
        try Data(#"{"theme": "dark"}"#.utf8).write(to: real)
        try FileManager.default.createSymbolicLink(at: claude.appendingPathComponent("settings.json"), withDestinationURL: real)

        let first = Init.installRules([.claudeCode, .codex], home: home.path)
        let count = AgentPermissionRules.rules.count
        #expect(first.failures.isEmpty)
        #expect(first.lines == ["Rules added to ~/.claude/settings.json (\(count) new)", "Rules added to ~/.codex/rules/offsider.rules (\(count) new)"])
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: claude.appendingPathComponent("settings.json").path) == real.path)
        #expect(try settings(Data(contentsOf: real))["theme"] as? String == "dark")
        let mode = try FileManager.default.attributesOfItem(atPath: real.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
        #expect(Init.rulesDoctorVerdict(home: home.path).status == .pass)

        let second = Init.installRules([.claudeCode, .codex], home: home.path)
        #expect(second.lines == ["Rules already present in ~/.claude/settings.json", "Rules already present in ~/.codex/rules/offsider.rules"])
    }

    @Test("a malformed settings file is left byte for byte and named in one line")
    func malformedLeftUntouched() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let claude = home.appendingPathComponent(".claude")
        try FileManager.default.createDirectory(at: claude, withIntermediateDirectories: true)
        let original = Data("{\"permissions\": {\"deny\": [}\n".utf8)
        try original.write(to: claude.appendingPathComponent("settings.json"))

        let result = Init.installRules([.claudeCode], home: home.path)
        #expect(result.lines.isEmpty)
        #expect(result.failures == ["~/.claude/settings.json is not valid JSON, so it was left as is. Fix it, then run offsider init --rules-only."])
        #expect(try Data(contentsOf: claude.appendingPathComponent("settings.json")) == original)
        #expect(Init.rulesDoctorVerdict(home: home.path).status == .warn)
    }
}
