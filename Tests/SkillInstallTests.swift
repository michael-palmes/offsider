import Foundation
import OffsiderCore
import Testing

@Suite("Skill install")
struct SkillInstallTests {
    static let bundled = Data("---\nname: offsider\ndescription: this build\n---\n# Offsider\n".utf8)

    @Test("a missing skill installs, the same bytes are up to date, an older Offsider skill updates and another skill needs --force")
    func actions() {
        let older = Data("---\nname: offsider\ndescription: an older build\n---\n".utf8)
        let foreign = Data("---\nname: something-else\n---\nname: offsider\n".utf8)
        #expect(SkillInstall.action(existing: nil, bundled: Self.bundled, force: false) == .install)
        #expect(SkillInstall.action(existing: Self.bundled, bundled: Self.bundled, force: false) == .upToDate)
        #expect(SkillInstall.action(existing: Self.bundled, bundled: Self.bundled, force: true) == .upToDate)
        #expect(SkillInstall.action(existing: older, bundled: Self.bundled, force: false) == .update)
        #expect(SkillInstall.action(existing: foreign, bundled: Self.bundled, force: false) == .refuse)
        #expect(SkillInstall.action(existing: Data("plain text".utf8), bundled: Self.bundled, force: false) == .refuse)
        #expect(SkillInstall.action(existing: foreign, bundled: Self.bundled, force: true) == .update)
    }

    @Test("a skills folder symlinked to another is one install target")
    func symlinkedFolderInstallsOnce() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let agents = root.appendingPathComponent(".agents/skills", isDirectory: true)
        let claude = root.appendingPathComponent(".claude/skills", isDirectory: true)
        try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: claude.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: claude, withDestinationURL: agents)

        let targets = SkillInstall.distinct([claude, agents]) { $0.resolvingSymlinksInPath().path }
        #expect(targets == [claude])
        let separate = root.appendingPathComponent("other/skills", isDirectory: true)
        #expect(SkillInstall.distinct([claude, separate, agents]) { $0.resolvingSymlinksInPath().path } == [claude, separate])
    }

    @Test("doctor's install.skill passes when every installed skill matches, warns on a stale one and skips with none")
    func doctorVerdict() {
        #expect(SkillInstall.doctorVerdict(installed: [], stale: [], agent: false).status == .skip)
        #expect(SkillInstall.doctorVerdict(installed: ["/a/SKILL.md"], stale: [], agent: false).status == .pass)
        let stale = SkillInstall.doctorVerdict(installed: ["/a/SKILL.md", "/b/SKILL.md"], stale: [("/b/SKILL.md", "agents")], agent: false)
        #expect(stale.status == .warn)
        #expect(stale.detail.contains("/b/SKILL.md"))
        #expect(stale.hint == "Run offsider init to update it.")
    }

    @Test("an agent, which has no terminal for init's picker, is told the init --client that updates each stale skill")
    func doctorVerdictForAnAgent() {
        let one = SkillInstall.doctorVerdict(installed: ["/a/SKILL.md"], stale: [("/a/SKILL.md", "claude")], agent: true)
        #expect(one.hint == "Run offsider init --client claude to update it.")
        let both = SkillInstall.doctorVerdict(installed: ["/a/SKILL.md", "/b/SKILL.md"], stale: [("/a/SKILL.md", "claude"), ("/b/SKILL.md", "agents")], agent: true)
        #expect(both.hint == "Run offsider init --client claude and offsider init --client agents to update them.")
        #expect(SkillInstall.doctorVerdict(installed: [], stale: [], agent: true, clients: ["agents"]).hint == "Run offsider init --client agents.")
        #expect(SkillInstall.doctorVerdict(installed: [], stale: [], agent: true).hint == "Run offsider init --client claude or offsider init --client agents.")
        #expect(SkillInstall.doctorVerdict(installed: [], stale: [], agent: false).hint == "Run offsider init.")
    }
}
