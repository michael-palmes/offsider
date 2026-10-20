import Foundation
import Testing
@testable import Offsider
@testable import OffsiderCore

@Suite("Init Command Tests")
struct InitTests {
    @Test("print outputs skill content")
    func printOutputsSkill() async throws {
        let result = try await TestHelpers.runOffsiderCommand("init --print")
        #expect(result.output.contains("name: offsider"))
        #expect(result.output.range(of: #"\baxe\b"#, options: [.regularExpression, .caseInsensitive]) == nil)
    }

    @Test("installs skill to custom destination")
    func installsToCustomDestination() async throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let skillsDir = tempRoot.appendingPathComponent("skills", isDirectory: true)

        defer {
            try? FileManager.default.removeItem(at: tempRoot)
        }

        _ = try await TestHelpers.runOffsiderCommand("init --dest \(skillsDir.path)")

        let installedFile = skillsDir.appendingPathComponent("offsider/SKILL.md").path
        #expect(FileManager.default.fileExists(atPath: installedFile))
    }

    @Test("another skill in the offsider folder needs --force; Offsider's own older skill is updated without it")
    func existingSkillRequiresForce() async throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let skillsDir = tempRoot.appendingPathComponent("skills", isDirectory: true)
        let installedDir = skillsDir.appendingPathComponent("offsider", isDirectory: true)
        let installedFile = installedDir.appendingPathComponent("SKILL.md", isDirectory: false)

        try FileManager.default.createDirectory(at: installedDir, withIntermediateDirectories: true)
        try "old-content".write(to: installedFile, atomically: true, encoding: .utf8)

        defer {
            try? FileManager.default.removeItem(at: tempRoot)
        }

        let failedResult = try await TestHelpers.runOffsiderCommandAllowFailure("init --dest \(skillsDir.path)")
        #expect(failedResult.exitCode != 0)
        #expect(failedResult.output.contains("Another skill named offsider is at \(installedFile.path). Re-run with --force to replace it."))
        #expect(try String(contentsOf: installedFile, encoding: .utf8) == "old-content")

        _ = try await TestHelpers.runOffsiderCommand("init --dest \(skillsDir.path) --force")
        #expect(try String(contentsOf: installedFile, encoding: .utf8).contains("name: offsider"))

        try "---\nname: offsider\ndescription: an older build\n---\n# Offsider\n".write(to: installedFile, atomically: true, encoding: .utf8)
        let updated = try await TestHelpers.runOffsiderCommand("init --dest \(skillsDir.path)")
        #expect(updated.output.contains("Updated Offsider skill -> Custom: \(installedFile.path)"))
        #expect(!(try String(contentsOf: installedFile, encoding: .utf8).contains("an older build")))
    }

    @Test("running init twice says the skill is already up to date and points at doctor")
    func secondRunIsUpToDate() async throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let skillsDir = tempRoot.appendingPathComponent("skills", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let first = try await TestHelpers.runOffsiderCommand("init --dest \(skillsDir.path)")
        #expect(first.output.contains("Installed Offsider skill -> Custom: "))
        let second = try await TestHelpers.runOffsiderCommand("init --dest \(skillsDir.path)")
        #expect(second.output.contains("Already up to date -> Custom: \(skillsDir.path)/offsider/SKILL.md"))
        #expect(second.output.hasSuffix("Next: offsider doctor\n"))
    }

    @Test("uninstall removes installed directory")
    func uninstallRemovesInstalledDirectory() async throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let skillsDir = tempRoot.appendingPathComponent("skills", isDirectory: true)

        defer {
            try? FileManager.default.removeItem(at: tempRoot)
        }

        _ = try await TestHelpers.runOffsiderCommand("init --dest \(skillsDir.path)")
        _ = try await TestHelpers.runOffsiderCommand("init --dest \(skillsDir.path) --uninstall")

        let installedDirectory = skillsDir.appendingPathComponent("offsider", isDirectory: true).path
        #expect(!FileManager.default.fileExists(atPath: installedDirectory))
    }

    @Test("non-interactive mode requires explicit target")
    func nonInteractiveModeRequiresExplicitTarget() async throws {
        let result = try await TestHelpers.runOffsiderCommandAllowFailure("init")
        #expect(result.exitCode != 0)
        #expect(result.output.contains("Non-interactive mode requires --client or --dest"))
    }

    @Test("refuses root destination")
    func refusesRootDestination() async throws {
        let result = try await TestHelpers.runOffsiderCommandAllowFailure("init --dest /")
        #expect(result.exitCode != 0)
        #expect(result.output.contains("filesystem root"))
    }

    @Test("on a terminal with two agents' folders, every one starts ticked and Space unticks one before Enter")
    func chooseAgentsTicks() throws {
        let targets = [("Claude Code", "/Users/me/.claude/skills"), ("Agents Skills", "/Users/me/.agents/skills")]
        let terminal = try AccessTerminal()
        terminal.type([" \r"])
        let chosen = try Init.chooseAgents(targets, descriptor: terminal.secondary, name: \.0, folder: \.1)
        #expect(chosen.map(\.0) == ["Agents Skills"])
        let transcript = terminal.finish()
        #expect(transcript.contains("\(InitScreen.agentsQuestion) \(TerminalUI.Controls(ticking: true).text(style: .detect(isTerminal: true)))"))
        #expect(transcript.contains("[x]  Claude Code"))
        let shared = [("Claude Code", "/Users/me/.agents/skills"), ("Agents Skills", "/Users/me/.agents/skills")]
        #expect(try Init.chooseAgents(shared, descriptor: -1, name: \.0, folder: \.1).count == 2)
    }

    private func temporaryHome(_ folders: [String]) throws -> URL {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        for folder in [""] + folders {
            try FileManager.default.createDirectory(at: home.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        return home
    }

    @Test("non-interactive --client claude installs the skill and the rules, and a second run adds nothing")
    func clientClaudeInstallsRules() async throws {
        let home = try temporaryHome([".claude", ".codex"])
        defer { try? FileManager.default.removeItem(at: home) }
        let count = AgentPermissionRules.rules.count

        let first = try await TestHelpers.runOffsiderCommand("init --client claude", environment: ["HOME": home.path])
        #expect(first.output.contains("Rules added to ~/.claude/settings.json (\(count) new)"))
        #expect(!first.output.contains(".codex"), "only the chosen client gets rules")
        #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent(".codex/rules").path))
        #expect(first.output.hasSuffix("Next: offsider doctor\n"))

        let second = try await TestHelpers.runOffsiderCommand("init --client claude", environment: ["HOME": home.path])
        #expect(second.output.contains("Rules already present in ~/.claude/settings.json"))
    }

    @Test("--client claude with no ~/.claude folder installs the skill but writes no settings")
    func noRulesForAbsentAgent() async throws {
        let home = try temporaryHome([])
        defer { try? FileManager.default.removeItem(at: home) }
        let result = try await TestHelpers.runOffsiderCommand("init --client claude", environment: ["HOME": home.path])
        #expect(!result.output.contains("Rules"))
        #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent(".claude/settings.json").path))
    }

    @Test("--no-rules installs only the skill; --rules-only adds only the rules for every agent installed")
    func rulesFlags() async throws {
        let home = try temporaryHome([".claude", ".codex"])
        defer { try? FileManager.default.removeItem(at: home) }

        let skillOnly = try await TestHelpers.runOffsiderCommand("init --client claude --no-rules", environment: ["HOME": home.path])
        #expect(!skillOnly.output.contains("Rules"))
        #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent(".claude/settings.json").path))

        try FileManager.default.removeItem(at: home.appendingPathComponent(".claude/skills"))
        let rulesOnly = try await TestHelpers.runOffsiderCommand("init --rules-only", environment: ["HOME": home.path])
        #expect(rulesOnly.output.contains("Rules added to ~/.claude/settings.json"))
        #expect(rulesOnly.output.contains("Rules added to ~/.codex/rules/offsider.rules"))
        #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent(".claude/skills").path))

        let nowhere = try temporaryHome([])
        defer { try? FileManager.default.removeItem(at: nowhere) }
        let refused = try await TestHelpers.runOffsiderCommandAllowFailure("init --rules-only", environment: ["HOME": nowhere.path])
        #expect(refused.exitCode != 0)
        #expect(!FileManager.default.fileExists(atPath: nowhere.appendingPathComponent(".claude").path))
    }

    @Test("a malformed settings file fails the run, names the file and stays as it was")
    func malformedSettingsFails() async throws {
        let home = try temporaryHome([".claude"])
        defer { try? FileManager.default.removeItem(at: home) }
        let file = home.appendingPathComponent(".claude/settings.json")
        try "{not json".write(to: file, atomically: true, encoding: .utf8)
        let result = try await TestHelpers.runOffsiderCommandAllowFailure("init --rules-only", environment: ["HOME": home.path])
        #expect(result.exitCode != 0)
        #expect(result.output.contains("~/.claude/settings.json is not valid JSON"))
        #expect(try String(contentsOf: file, encoding: .utf8) == "{not json")
    }

    @Test("--print-rules prints valid JSON with both agents' rules and refuses other options")
    func printRules() async throws {
        let result = try await TestHelpers.runOffsiderCommand("init --print-rules")
        let object = try #require(try JSONSerialization.jsonObject(with: Data(result.output.utf8)) as? [String: Any])
        let claude = try #require(object["claude"] as? [String: Any])
        let permissions = try #require(claude["permissions"] as? [String: [String]])
        #expect(permissions["deny"] == AgentPermissionRules.patterns(.deny))
        #expect((object["codex"] as? [String: Any])?["rules"] as? [String] != nil)
        #expect((object["rules"] as? [[String: String]])?.count == AgentPermissionRules.rules.count)

        let refused = try await TestHelpers.runOffsiderCommandAllowFailure("init --print-rules --client claude")
        #expect(refused.exitCode != 0)
    }

    @Test("the picker adds a ticked permission rules row per installed agent, and unticking one skips it")
    func pickerRulesRows() throws {
        let targets = [("Claude Code", "/Users/me/.claude/skills")]
        let terminal = try AccessTerminal()
        terminal.type(["jj \r"])
        let chosen = try Init.chooseInstall(targets, rules: [.claudeCode, .codex], descriptor: terminal.secondary, name: \.0, folder: \.1)
        #expect(chosen.skills.map(\.0) == ["Claude Code"])
        #expect(chosen.rules == [.claudeCode])
        #expect(terminal.transcript.contains("Permission rules for Codex"))
        #expect(terminal.transcript.contains(AgentPermissionRules.pickerDetail))
        #expect(try Init.chooseInstall(targets, rules: [], descriptor: -1, name: \.0, folder: \.1).skills.count == 1)
    }
}
