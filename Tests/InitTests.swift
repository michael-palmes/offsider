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
        #expect(terminal.transcript.contains("\(InitScreen.agentsQuestion) \(TerminalUI.Controls(ticking: true).text(style: .detect(isTerminal: true)))"))
        #expect(terminal.transcript.contains("[x]  Claude Code"))
        let shared = [("Claude Code", "/Users/me/.agents/skills"), ("Agents Skills", "/Users/me/.agents/skills")]
        #expect(try Init.chooseAgents(shared, descriptor: -1, name: \.0, folder: \.1).count == 2)
    }
}
