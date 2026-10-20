import Foundation
import Testing
@testable import Offsider
@testable import OffsiderCore

@Suite("Init screen")
struct InitScreenTests {
    static let steps = [
        InitScreen.Step(.installed, who: "Claude Code", path: "/Users/me/.claude/skills/offsider/SKILL.md", line: "Installed Offsider skill -> Claude Code: /Users/me/.claude/skills/offsider/SKILL.md"),
        InitScreen.Step(.rulesAdded(5), who: "Claude Code", path: "~/.claude/settings.json", line: "Rules added to ~/.claude/settings.json (5 new)"),
        InitScreen.Step(.rulesPresent, who: "Codex", path: "~/.codex/rules/offsider.rules", line: "Rules already present in ~/.codex/rules/offsider.rules"),
    ]

    static func render(_ page: Page, out: Console.Channel, err: Console.Channel) -> ConsoleCapture {
        let capture = ConsoleCapture()
        capture.console(out: out, err: err).show(page)
        return capture
    }

    @Test("an agent or a pipe reads init's plain lines and the Next line, nothing else")
    func agentLines() {
        let capture = Self.render(InitScreen.page(Self.steps, next: "offsider doctor", home: "/Users/me"), out: .agent, err: .agent)
        #expect(capture.out == Self.steps.map { $0.line + "\n" }.joined() + "Next: offsider doctor\n")
        #expect(capture.err.isEmpty)
    }

    @Test("a person sees a row per folder with home as ~, a closing, and the next command on stderr")
    func personRows() {
        let capture = Self.render(InitScreen.page(Self.steps, next: "offsider doctor", home: "/Users/me"), out: .person(), err: .person())
        let lines = capture.out.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        #expect(lines.contains { $0.hasPrefix("  ✓ Skill") && $0.contains("~/.claude/skills/offsider/SKILL.md installed") })
        #expect(lines.contains { $0.hasPrefix("  ✓ Rules") && $0.contains("5 new") })
        #expect(lines.contains { $0.hasPrefix("  - Rules") && $0.contains("Codex") && $0.hasSuffix("up to date") })
        #expect(lines.contains("✅  Ready for your agents"))
        #expect(!capture.out.contains("/Users/me") && !capture.out.contains("->"))
        #expect(capture.err == "\nNext  offsider doctor\n")
    }

    @Test("nothing changed reads as up to date; an uninstall as removed; nothing to remove keeps an agent's line")
    func closings() {
        let unchanged = [InitScreen.Step(.upToDate, who: "Custom", path: "/tmp/skills/offsider/SKILL.md", line: "Already up to date -> Custom: /tmp/skills/offsider/SKILL.md")]
        #expect(Self.render(InitScreen.page(unchanged), out: .person(), err: .person()).out.contains("✅  Already up to date"))
        let removed = [InitScreen.Step(.removed, who: "Claude Code", path: "/Users/me/.claude/skills/offsider", line: "Removed Offsider skill -> Claude Code: /Users/me/.claude/skills/offsider")]
        #expect(Self.render(InitScreen.page(removed, home: "/Users/me"), out: .person(), err: .person()).out.contains("✅  Offsider skill removed"))
        #expect(Self.render(InitScreen.nothingToRemove, out: .agent, err: .agent).out == "No installed Offsider skill directories were found.\n")
        #expect(Self.render(InitScreen.nothingToRemove, out: .person(), err: .person()).out.hasPrefix("✅  Nothing to remove"))
    }
}
